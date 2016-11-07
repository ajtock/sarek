#!/usr/bin/env nextflow

/*
vim: syntax=groovy
-*- mode: groovy;-*-
========================================================================================
=                   C A N C E R    A N A L Y S I S    W O R K F L O W                  =
========================================================================================
 New Cancer Analysis Workflow. Started March 2016.

 @Authors
 Sebastian DiLorenzo <sebastian.dilorenzo@bils.se> [@Sebastian-D]
 Jesper Eisfeldt <jesper.eisfeldt@scilifelab.se> [@J35P312]
 Maxime Garcia <maxime.garcia@scilifelab.se> [@MaxUlysse]
 Szilveszter Juhos <szilveszter.juhos@scilifelab.se> [@szilvajuhos]
 Max Käller <max.kaller@scilifelab.se> [@gulfshores]
 Malin Larsson <malin.larsson@scilifelab.se> [@malinlarsson]
 Björn Nystedt <bjorn.nystedt@scilifelab.se> [@bjornnystedt]
 Pall Olason <pall.olason@scilifelab.se> [@pallolason]
 Pelin Sahlén <pelin.akan@scilifelab.se> [@pelinakan]

----------------------------------------------------------------------------------------
 Basic command:
 $ nextflow run SciLifeLab/CAW -c <file.config> --sample <sample.tsv>

 All variables are configured in the config and sample files. All variables in the config
 file can be reconfigured on the commande line, like:
 --option <option>
----------------------------------------------------------------------------------------
 Workflow processes overview:
 - Mapping - Map reads with BWA
 - MergeBam - Merge BAMs if multilane samples
 - RenameSingleBam - Rename BAM if non-multilane sample
 - MarkDuplicates - using Picard
 - CreateIntervals - using GATK
 - Realign - using GATK
 - CreateRecalibrationTable - using GATK
 - RecalibrateBam - using GATK
 - RunMutect1 - using MuTect1 1.1.5 loaded as a module
 - RunMutect2 - using MuTect2 shipped in GATK
 - VarDict - run VarDict on multiple intervals
 - VarDictCollatedVCF - merge Vardict result
----------------------------------------------------------------------------------------

========================================================================================
=                               C O N F I G U R A T I O N                              =
========================================================================================
*/

revision = grab_git_revision() ?: ''
version  = "v0.8.5"
refsDefined = true
stepCorrect = true
workflowSteps = []

if( workflow.profile == 'standard' && !params.project ) exit 1, "No UPPMAX project ID found! Use --project" 

/*
 * Arguments handling
 * Use steps to run some processes and skip others
 * Borrowed the idea from https://github.com/guigolab/grape-nf
 * and from https://github.com/NBISweden/wgs-structvar
 */

switch (params) {
  case {params.help} :
    help_message("$version", "$revision")
    exit 1

  case {params.version} :
    version_message("$version", "$revision")
    exit 1

  case {params.steps} : //Getting list of steps from comma-separated strings
    workflowSteps = params.steps.split(',').collect { it.trim() }
    break
}

/*
 * Define lists of refs, steps and outDir
 */

refs = [
  "genomeFile":   params.genome,       // genome reference
  "genomeIndex":  params.genomeIndex,  // genome reference index
  "genomeDict":   params.genomeDict,   // genome reference dictionary
  "kgIndels":     params.kgIndels,     // 1000 Genomes SNPs
  "kgIndex":      params.kgIndex,      // 1000 Genomes SNPs index
  "dbsnp":        params.dbsnp,        // dbSNP
  "dbsnpIndex":   params.dbsnpIndex,   // dbSNP index
  "millsIndels":  params.millsIndels,  // Mill's Golden set of SNPs
  "millsIndex":   params.millsIndex,   // Mill's Golden set index
  "cosmic41":     params.cosmic41,     // cosmic vcf file with VCF4.1 header
  "cosmic":       params.cosmic,       // cosmic vcf file
  "intervals":    params.intervals,    // intervals file for spread-and-gather processes (usually chromosome chunks at centromeres)
  "MantaRef":     params.mantaRef,     // copy of the genome reference file
  "MantaIndex":   params.mantaIndex,   // reference index indexed with samtools/0.1.19
  "acLoci":       params.acLoci        // loci file for ascat
]

stepsList = [
  "preprocessing",
  "realign",
  "skipPreprocessing",
  "MuTect1",
  "MuTect2",
  "VarDict",
  "Strelka",
  "HaplotypeCaller",
  "Manta",
  "ascat"
]

outDir = [
  "preprocessing"   : 'Preprocessing',
  "nonRealigned"    : 'Preprocessing/NonRealigned',
  "recalibrated"    : 'Preprocessing/Recalibrated',
  "VariantCalling"  : 'VariantCalling',
  "MuTect1"         : 'VariantCalling/MuTect1',
  "MuTect2"         : 'VariantCalling/MuTect2',
  "VarDict"         : 'VariantCalling/VarDictJava',
  "Strelka"         : 'VariantCalling/Strelka',
  "HaplotypeCaller" : 'VariantCalling/HaplotypeCaller',
  "Manta"           : 'VariantCalling/Manta',
  "ascat"           : 'VariantCalling/ascat'
]

/*
 * Loop through all the references files (params.* defined in the config file) to verify if they really exist.
 */

refs.each { referenceFile, fileToCheck ->
  test = checkRefExistence(referenceFile, fileToCheck)
  !(test) ? refsDefined = false : ""
}

if (!refsDefined) {
  exit 1, 'Missing Reference file(s), see --help for more information'
}

/*
 * Loop through all the possible steps to verify if they are correctly spelled or if they exist.
 */

workflowSteps.each { step ->
  test = checkStepExistence(step, stepsList)
  !(test) ? stepCorrect = false : ""
}

if (!stepCorrect) {
  exit 1, 'Unknown step parameter(s), see --help for more information'
}

if (('preprocessing' in workflowSteps && ('realign' in workflowSteps || 'skipPreprocessing' in workflowSteps)) || ('realign' in workflowSteps && 'skipPreprocessing' in workflowSteps)) {
  exit 1, 'Please choose only one step between preprocessing, realign and skipPreprocessing, see --help for more information'
}

if (!('preprocessing' in workflowSteps) && !('realign' in workflowSteps) && !('skipPreprocessing' in workflowSteps) ) {
  workflowSteps.add('preprocessing')
}

if (!params.sample) {
  exit 1, 'Missing TSV file, see --help for more information'
}

/*
 * Extract and verify content of TSV file
 */

fastqFiles = Channel.create()
bamFiles = Channel.create()

if ('preprocessing' in workflowSteps) {
  fastqFiles = extractFastqFiles(file(params.sample))
  fastqFiles = fastqFiles.view { it -> "FASTQ files and IDs to process: $it" }
  bamFiles.close()
} else if ( 'realign' in workflowSteps || 'skipPreprocessing' in workflowSteps) {
  bamFiles = extractBamFiles(file(params.sample))
  bamFiles = bamFiles.view { it -> "Bam files and IDs to process: $it" }
  fastqFiles.close()
}

start_message("$version", "$revision")

/*
========================================================================================
=                                   P R O C E S S E S                                  =
========================================================================================
*/

if ('preprocessing' in workflowSteps) {
  println file(outDir["preprocessing"]).mkdir() ? "Folder ${outDir['preprocessing']} created" : "Cannot create folder ${outDir['preprocessing']}"
  println file(outDir["nonRealigned"]).mkdir() ? "Folder ${outDir['nonRealigned']} created" : "Cannot create folder ${outDir['nonRealigned']}"
  println file(outDir["recalibrated"]).mkdir() ? "Folder ${outDir['recalibrated']} created" : "Cannot create folder ${outDir['recalibrated']}"
} else if ('realign' in workflowSteps) {
  println file(outDir['preprocessing']).mkdir() ? "Folder ${outDir['preprocessing']} created" : "Cannot create folder ${outDir['preprocessing']}"
  println file(outDir['recalibrated']).mkdir() ? "Folder ${outDir['recalibrated']} created" : "Cannot create folder ${outDir['recalibrated']}"
}

process Mapping {
  tag { idRun }
  time { params.runTime * task.attempt }

  input:
  file refs["genomeFile"]
  set idPatient, idSample, idRun, file(fq1), file(fq2) from fastqFiles

  output:
  set idPatient, idSample, idRun, file("${idRun}.bam") into bams

  when: 'preprocessing' in workflowSteps

  script:
  readGroupString="\"@RG\\tID:${idRun}\\tSM:${idSample}\\tLB:${idSample}\\tPL:illumina\""

  """
  #!/bin/bash

  bwa mem -R ${readGroupString} -B 3 -t ${task.cpus} -M ${refs["genomeFile"]} ${fq1} ${fq2} | \
  samtools view -bS -t ${refs["genomeIndex"]} - | \
  samtools sort - > ${idRun}.bam
  """
}

singleBam = Channel.create()
groupedBam = Channel.create()

if ('preprocessing' in workflowSteps) {
  bams = bams.view { it -> "BAM files before sorting into group or single: $it" }

  /*
   * Merge or rename bam
   *
   * Borrowed code from https://github.com/guigolab/chip-nf
   * Now, we decide whether bam is standalone or should be merged by idSample (column 1 from channel bams)
   * http://www.nextflow.io/docs/latest/operator.html?highlight=grouptuple#grouptuple
   */

  bams.groupTuple(by:[1])
    .choice(singleBam, groupedBam) { it[3].size() > 1 ? 1 : 0 }

  singleBam  = singleBam.view  { it -> "Single BAMs before merge: $it" }
  groupedBam = groupedBam.view { it -> "Grouped BAMs before merge: $it" }
} else {
  singleBam.close()
  groupedBam.close()
}

process MergeBam {
  tag { idSample }

  cpus 1
  queue 'core'
  memory { params.singleCPUMem * task.attempt }
  time { params.runTime * task.attempt }

  input:
  set idPatient, idSample, idRun, file(bam) from groupedBam

  output:
  set idPatient, idSample, file("${idSample}.bam") into mergedBam

  when: 'preprocessing' in workflowSteps

  script:
  idRun = idRun.sort().join(':')
  """
  #!/bin/bash

  echo -e "idPatient:\t"${idPatient}"\nidSample:\t"${idSample}"\nidRun:\t"${idRun}"\nbam:\t"${bam}"\n" > logInfo
  samtools merge ${idSample}.bam ${bam}
  """
}

process RenameSingleBam {
  // Renaming is totally useless, but the file name is consistent with the rest of the pipeline
  tag { idSample }

  cpus 1
  queue 'core'

  input:
  set idPatient, idSample, idRun, file(bam) from singleBam

  output:
  set idPatient, idSample, file("${idSample}.bam") into singleRenamedBam

  when: 'preprocessing' in workflowSteps

  script:
  """
  #!/bin/bash

  mv ${bam} ${idSample}.bam
  """
}

bamList = Channel.create()

if ('preprocessing' in workflowSteps) {
  singleRenamedBam = singleRenamedBam.view { it -> "SINGLES: $it" }
  mergedBam = mergedBam.view { it -> "GROUPED: $it" }

  /*
   * merge all bams (merged and singles) to a single channel
   */

  bamList = mergedBam.mix(singleRenamedBam)
  bamList = bamList.map { idPatient, idSample, bam -> [idPatient[0], idSample, bam].flatten() }
  bamList = bamList.view { it -> "GROUPEDBAM list for MarkDuplicates: $it" }
} else if ('realign' in workflowSteps) {
  bamList = bamFiles.map { idPatient, idSample, bamFile, baiFile -> [idPatient, idSample, bamFile] }
  bamList = bamList.view { it -> "BAM list for MarkDuplicates: $it" }
} else {
  bamList.close()
}


process MarkDuplicates {
  /*
   *  mark duplicates all bams
   */
  tag { idSample }

  cpus 1
  queue 'core'
  memory { params.singleCPUMem * task.attempt }
  time { params.runTime * task.attempt }

  input:
  set idPatient, idSample, file(bam) from bamList

  // Channel content should be in the log before
  // The output channels are duplicated nevertheless, one copy goes to RealignerTargetCreator (CreateIntervals)
  // and the other to IndelRealigner

  output:
  set idPatient, idSample, file("${idSample}.md.bam"), file("${idSample}.md.bai") into duplicates

  when: 'preprocessing' in workflowSteps || 'realign' in workflowSteps

  script:
  """
  #!/bin/bash

  echo -e "idPatient:\t"${idPatient}"\nidSample:\t"${idSample}"\nbam:\t"${bam}"\n" > logInfo
  java -Xmx${task.memory.toGiga()}g -jar ${params.picardHome}/MarkDuplicates.jar \
  INPUT=${bam} \
  METRICS_FILE=${bam}.metrics \
  TMP_DIR=. \
  ASSUME_SORTED=true \
  VALIDATION_STRINGENCY=LENIENT \
  CREATE_INDEX=TRUE \
  OUTPUT=${idSample}.md.bam
  """
}

duplicatesGrouped  = Channel.create()
duplicatesInterval = Channel.create()
duplicatesRealign  = Channel.create()

if ('preprocessing' in workflowSteps || 'realign' in workflowSteps) {
  /*
   * create realign intervals, use both tumor+normal as input
   */

  // group the marked duplicates Bams for intervals by overall subject/patient id (idPatient)
  // group the marked duplicates Bams for realign by overall subject/patient id (idPatient)
  duplicatesGrouped = duplicates.groupTuple()
  (duplicatesInterval, duplicatesRealign) = copyChannel(duplicatesGrouped)

  duplicatesInterval = duplicatesInterval.view { it -> "BAMs for RealignerTargetCreator grouped by overall subject/patient ID: $it" }
  duplicatesRealign  = duplicatesRealign.view  { it -> "BAMs for IndelRealigner grouped by overall subject/patient ID: $it" }
} else {
  duplicatesGrouped.close()
  duplicatesInterval.close()
  duplicatesRealign.close()
}

intervals = Channel.create()

process CreateIntervals {
  /*
   * Creating target intervals for indel realigner.
   * Though VCF indexes are not needed explicitly, we are adding them so they will be linked, and not re-created on the fly.
   */
  tag { idPatient }

  time { params.runTime * task.attempt }

  input:
  set idPatient, idSample, file(mdBam), file(mdBai) from duplicatesInterval
  file gf from file(refs["genomeFile"])
  file gi from file(refs["genomeIndex"])
  file gd from file(refs["genomeDict"])
  file ki from file(refs["kgIndels"])
  file kix from file(refs["kgIndex"])
  file mi from file(refs["millsIndels"])
  file mix from file(refs["millsIndex"])

  output:
  file("${idPatient}.intervals") into intervals

  when: 'preprocessing' in workflowSteps || 'realign' in workflowSteps

  script:
  input = mdBam.collect{"-I $it"}.join(' ')
  """
  #!/bin/bash

  echo -e "idPatient:\t"${idPatient}"\nidSample:\t"${idSample}"\nmdBam:\t"${mdBam}"\n" > logInfo
  java -Xmx${task.memory.toGiga()}g -jar ${params.gatkHome}/GenomeAnalysisTK.jar \
  -T RealignerTargetCreator \
  $input \
  -R $gf \
  -known $ki \
  -known $mi \
  -nt ${task.cpus} \
  -XL hs37d5 \
  -o ${idPatient}.intervals
  """
}

if ('preprocessing' in workflowSteps || 'realign' in workflowSteps) {
  intervals = intervals.view { it -> "Intervals passed to Realign: $it" }
} else {
  intervals.close()
}

process Realign {
  /*
   * realign, use nWayOut to split into tumor/normal again
   */
  tag { idPatient }

  publishDir outDir["nonRealigned"], mode: 'copy'

  time { params.runTime * task.attempt }

  input:
  set idPatient, idSample, file(mdBam), file(mdBai) from duplicatesRealign
  file gf from file(refs["genomeFile"])
  file gi from file(refs["genomeIndex"])
  file gd from file(refs["genomeDict"])
  file ki from file(refs["kgIndels"])
  file kix from file(refs["kgIndex"])
  file mi from file(refs["millsIndels"])
  file mix from file(refs["millsIndex"])
  file intervals from intervals

  output:
  val(idPatient) into idPatient
  val(idSample) into tempSamples
  file("*.md.real.bam") into tempBams
  file("*.md.real.bai") into tempBais

  when: 'preprocessing' in workflowSteps || 'realign' in workflowSteps

  script:
  input = mdBam.collect{"-I $it"}.join(' ')

  """
  #!/bin/bash

  touch ${workflow.launchDir}/${outDir["nonRealigned"]}/${idPatient}.tsv

  for i in $idSample ;do
      sample=\$(echo \$i | tr -d '[],')
      echo -e ${idPatient}\t\$(echo \$sample | cut -d_ -f 3)\t\$(echo \$sample | cut -d_ -f 1)\t${outDir["nonRealigned"]}/\$sample.md.real.bam\t${outDir["nonRealigned"]}/\$sample.md.real.bai >> ${workflow.launchDir}/${outDir["nonRealigned"]}/${idPatient}.tsv
  done

  echo -e "idPatient:\t"${idPatient}"\nidSample:\t"${idSample}"\nmdBam:\t"${mdBam}"\nmdBai:\t"${mdBai}"\n" > logInfo
  java -Xmx${task.memory.toGiga()}g -jar ${params.gatkHome}/GenomeAnalysisTK.jar \
  -T IndelRealigner \
  $input \
  -R $gf \
  -targetIntervals $intervals \
  -known $ki \
  -known $mi \
  -XL hs37d5 \
  -nWayOut '.real.bam'
  """
}

realignedBam = Channel.create()

if ('preprocessing' in workflowSteps || 'realign' in workflowSteps) {
  // If I make a set out of this process I got a list of lists, which cannot be iterate via a single process
  // So I need to transform this output into a channel that can be iterated on.
  // I also had problems with the set that wasn't synchronised, and I got wrongly associated files
  // So what I decided was to separate all the different output
  // We're getting from the Realign process 4 channels (patient, samples bams and bais)
  // So I flatten, sort, and reflatten the samples and the files (bam and bai) channels
  // to get them in the same order (the name of the bam and bai files are based on the sample, so if we sort them they all have the same order ;-))
  // And put them back together, and add the ID patient in the realignedBam channel

  tempSamples = tempSamples.flatten().toSortedList().flatten()
  tempBams = tempBams.flatten().toSortedList().flatten()
  tempBais = tempBais.flatten().toSortedList().flatten()
  tempSamples = tempSamples.merge( tempBams, tempBais ) { s, b, i -> [s, b, i] }
  realignedBam = idPatient.spread(tempSamples)
  realignedBam = realignedBam.view { it -> "realignedBam to BaseRecalibrator: $it" }
} else {
  realignedBam.close()
}

recalibrationTable = Channel.create()

process CreateRecalibrationTable {
  tag { idSample }

  time { params.runTime * task.attempt }

  input:
  set idPatient, idSample, file(realignedBamFile), file(realignedBaiFile) from realignedBam
  file refs["genomeFile"]
  file refs["dbsnp"]
  file refs["kgIndels"]
  file refs["millsIndels"]

  output:
  set idPatient, idSample, file(realignedBamFile), file(realignedBaiFile), file("${idSample}.recal.table") into recalibrationTable

  when: 'preprocessing' in workflowSteps || 'realign' in workflowSteps

  script:
  """
  #!/bin/bash

  java -Xmx${task.memory.toGiga()}g -Djava.io.tmpdir="/tmp" \
  -jar ${params.gatkHome}/GenomeAnalysisTK.jar \
  -T BaseRecalibrator \
  -R ${refs["genomeFile"]} \
  -I $realignedBamFile \
  -knownSites ${refs["dbsnp"]} \
  -knownSites ${refs["kgIndels"]} \
  -knownSites ${refs["millsIndels"]} \
  -nct ${task.cpus} \
  -XL hs37d5 \
  -l INFO \
  -o ${idSample}.recal.table
  """
}
if ('preprocessing' in workflowSteps || 'realign' in workflowSteps) {
  recalibrationTable = recalibrationTable.view { it -> "Base recalibrated table for recalibration: $it" }
} else {
  recalibrationTable.close()
}

recalibratedBams = Channel.create()

process RecalibrateBam {
  tag { idSample }

  publishDir outDir["recalibrated"], mode: 'copy'

  time { params.runTime * task.attempt }

  input:
  set idPatient, idSample, file(realignedBamFile), file(realignedBaiFile), recalibrationReport from recalibrationTable
  file refs["genomeFile"]

  output:
  set idPatient, idSample, file("${idSample}.recal.bam"), file("${idSample}.recal.bai") into recalibratedBams

  when: 'preprocessing' in workflowSteps || 'realign' in workflowSteps

  // TODO: ditto as at the previous BaseRecalibrator step, consider using -nct 4
  script:
  """
  #!/bin/bash

  touch ${workflow.launchDir}/${outDir["recalibrated"]}/${idPatient}.tsv
  echo -e ${idPatient}\t\$(echo $idSample | cut -d_ -f 3)\t\$(echo $idSample | cut -d_ -f 1)\t${outDir["recalibrated"]}/${idSample}.recal.bam\t${outDir["recalibrated"]}/${idSample}.recal.bai >> ${workflow.launchDir}/${outDir["recalibrated"]}/${idPatient}.tsv

  java -Xmx${task.memory.toGiga()}g \
  -jar ${params.gatkHome}/GenomeAnalysisTK.jar \
  -T PrintReads \
  -R ${refs["genomeFile"]} \
  -nct ${task.cpus} \
  -I $realignedBamFile \
  -XL hs37d5 \
  --BQSR $recalibrationReport \
  -o ${idSample}.recal.bam
  """
}

if ('skipPreprocessing' in workflowSteps) {
  recalibratedBams = bamFiles
  bamFiles.close()
}

recalibratedBams = recalibratedBams.view { it -> "Recalibrated Bam for variant Calling: $it" }

// Here we have a recalibrated bam set, but we need to separate the bam files based on patient status.
// The sample tsv config file which is formatted like: "subject status sample lane fastq1 fastq2"
// cf fastqFiles channel, I decided just to add __status to the sample name to have less changes to do.
// And so I'm sorting the channel if the sample match __0, then it's a normal sample, otherwise tumor.
// Then spread normal over tumor to get each possibilities
// ie. normal vs tumor1, normal vs tumor2, normal vs tumor3
// then copy this channel into channels for each variant calling
// I guess it will still work even if we have multiple normal samples

bamsTumor = Channel.create()
bamsNormal = Channel.create()
bamsAll = Channel.create()

bamsForHC = Channel.create()
hcIntervals = Channel.create()
bamsFHC = Channel.create()

bamsForMuTect1 = Channel.create()
bamsFMT1 = Channel.create()
muTect1Intervals = Channel.create()

bamsForMuTect2 = Channel.create()
bamsFMT2 = Channel.create()
muTect2Intervals = Channel.create()

bamsForVarDict = Channel.create()
varDictIntervals = Channel.create()
bamsFVD = Channel.create()

bamsForStrelka = Channel.create()
bamsForManta = Channel.create()
bamsForAscat = Channel.create()

// separate recalibrate files by filename suffix (which is status): __0 means normal, __1 means tumor recalibrated BAM

recalibratedBams
  .choice(bamsTumor, bamsNormal) { it[1] =~ /__0$/ ? 1 : 0 }

bamsTumor  = bamsTumor.view  { it -> "Tumor Bam for variant Calling: $it" }
bamsNormal = bamsNormal.view { it -> "Normal Bam for variant Calling: $it" }

// We know that MuTect2 (and other somatic callers) are notoriously slow. To speed them up we are chopping the reference into
// smaller pieces at centromeres (see repeats/centromeres.list), do variant calling by this intervals, and re-merge the VCFs.
// Since we are on a cluster, this can parallelize the variant call processes, and push down the variant call wall clock time significanlty.

// in fact we need two channels: one for the actual genomic region, and an other for names
// without ":", as nextflow is not happy with them (will report as a failed process).
// For region 1:1-2000 the output file name will be something like 1_1-2000_Sample_name.mutect2.vcf
// from the "1:1-2000" string make ["1:1-2000","1_1-2000"]

intervals = Channel // define intervals file by --intervals
  .from(file(params.intervals).readLines())
gI = intervals
  .map {a -> [a,a.replaceFirst(/\:/,"_")]}

if ('HaplotypeCaller' in workflowSteps) {
  (bamsNormal, bamsForHC) = copyChannel(bamsNormal)
  (gI, hcIntervals)       = copyChannel(gI)
  bamsForHC   = bamsForHC.view   { it -> "Bams for HaplotypeCaller: $it" }
  hcIntervals = hcIntervals.view { it -> "Intervals for HaplotypeCaller: $it" }
  bamsFHC = bamsForHC.spread(hcIntervals)
  bamsFHC = bamsFHC.view { it -> "Bams with Intervals for HaplotypeCaller: $it" }
} else {
  bamsForHC.close()
  hcIntervals.close()
  bamsFHC.close()
}

bamsAll = bamsNormal.spread(bamsTumor)

// Since idPatientNormal and idPatientTumor are the same, I'm removing it from BamsAll Channel
// I don't think a groupTuple can be used to do that, but it could be a good idea to look if there is a nicer way to do that

bamsAll = bamsAll.map {
  idPatientNormal, idSampleNormal, bamNormal, baiNormal, idPatientTumor, idSampleTumor, bamTumor, baiTumor ->
  [idPatientNormal, idSampleNormal, bamNormal, baiNormal, idSampleTumor, bamTumor, baiTumor]
}

bamsAll = bamsAll.view { it -> "Mapped Recalibrated Bam for variant Calling: $it" }

if ('MuTect1' in workflowSteps) {
  (bamsAll, bamsForMuTect1) = copyChannel(bamsAll)
  (gI, muTect1Intervals)    = copyChannel(gI)
  bamsForMuTect1   = bamsForMuTect1.view   { it -> "Bams for MuTect1: $it" }
  muTect1Intervals = muTect1Intervals.view { it -> "Intervals for MuTect1: $it" }
  bamsFMT1 = bamsForMuTect1.spread(muTect1Intervals)
  bamsFMT1 = bamsFMT1.view { it -> "Bams with Intervals for MuTect1: $it" }
} else {
  bamsForMuTect1.close()
  muTect1Intervals.close()
  bamsFMT1.close()
}

if ('MuTect2' in workflowSteps) {
  (bamsAll, bamsForMuTect2) = copyChannel(bamsAll)
  (gI, muTect2Intervals)    = copyChannel(gI)
  bamsForMuTect2   = bamsForMuTect2.view   { it -> "Bams for MuTect2: $it" }
  muTect2Intervals = muTect2Intervals.view { it -> "Intervals for MuTect2: $it" }
  bamsFMT2 = bamsForMuTect2.spread(muTect2Intervals)
  bamsFMT2 = bamsFMT2.view { it -> "Bams with Intervals for MuTect2: $it" }
} else {
  bamsForMuTect2.close()
  muTect2Intervals.close()
  bamsFMT2.close()
}

if ('VarDict' in workflowSteps) {
  (bamsAll, bamsForVarDict) = copyChannel(bamsAll)
  (gI, varDictIntervals)    = copyChannel(gI)
  bamsForVarDict   = bamsForVarDict.view   { it -> "Bams for VarDict: $it" }
  varDictIntervals = varDictIntervals.view { it -> "Intervals for VarDict: $it" }
  bamsFVD = bamsFVD.spread(varDictIntervals)
  bamsFVD = bamsFVD.view { it -> "Bams with Intervals for VarDict: $it" }
} else {
  bamsForVarDict.close()
  varDictIntervals.close()
  bamsFVD.close()
}

if ('Strelka' in workflowSteps) {
  (bamsAll, bamsForStrelka) = copyChannel(bamsAll)
  bamsForStrelka = bamsForStrelka.view { it -> "Bams with Intervals for Strelka: $it" }
} else {
  bamsForStrelka.close()
}

if ('Manta' in workflowSteps) {
  (bamsAll, bamsForManta) = copyChannel(bamsAll)
  bamsForManta = bamsForManta.view { it -> "Bams with Intervals for Manta: $it" }
} else {
  bamsForManta.close()
}

if ('ascat' in workflowSteps) {
  (bamsAll, bamsForAscat) = copyChannel(bamsAll)
  bamsForAscat = bamsForAscat.view { it -> "Bams with Intervals for ascat: $it" }
} else {
  bamsForAscat.close()
}

// now add genomic intervals to the sample information
// join [idPatientNormal, idSampleNormal, bamNormal, baiNormal, idSampleTumor, bamTumor, baiTumor] and ["1:1-2000","1_1-2000"]
// and make a line for each interval

process RunMutect1 {
  publishDir outDir["Mutect1"] + "intervals_" + idPatient

  cpus 1 
  queue 'core'
  memory { params.MuTect1Mem * task.attempt }
  time { params.runTime * task.attempt }

  input:
  set idPatient, idSampleNormal, file(bamNormal), file(baiNormal), idSampleTumor, file(bamTumor), file(baiTumor), genInt, gen_int from bamsFMT1

  output:
  set idPatient, idSampleNormal, idSampleTumor, val("${gen_int}_${idSampleNormal}_${idSampleTumor}"), file("${gen_int}_${idSampleNormal}_${idSampleTumor}.mutect1.vcf") into mutect1VariantCallingOutput

  when: 'MuTect1' in workflowSteps

  script:
  """
  #!/bin/bash

  java -Xmx${task.memory.toGiga()}g -jar \${MUTECT_HOME}/muTect.jar \
  -T MuTect \
  -R ${refs["genomeFile"]} \
  --cosmic ${refs["cosmic41"]} \
  --dbsnp ${refs["dbsnp"]} \
  -I:normal $bamNormal \
  -I:tumor $bamTumor \
  -L \"${genInt}\" \
  --disable_auto_index_creation_and_locking_when_reading_rods \
  --out ${gen_int}_${idSampleNormal}_${idSampleTumor}.mutect1.call_stats.out \
  --vcf ${gen_int}_${idSampleNormal}_${idSampleTumor}.mutect1.vcf
  """
}
if ('MuTect1' in workflowSteps) {
  // TODO: this is a duplicate with MuTect2 (maybe other VC as well), should be implemented only at one part

  // we are expecting one patient, one normal, and usually one, but occasionally more than one tumor
  // samples (i.e. relapses). The actual calls are always related to the normal, but spread across
  // different intervals. So, we have to collate (merge) intervals for each tumor case if there are
  // more than one. Therefore, what we want to do is to filter the multiple tumor cases into separate
  // channels and collate them according to their stage.
  mutect1VariantCallingOutput = mutect1VariantCallingOutput.view { it -> "Mutect1 output: $it" }
  filesToCollate = mutect1VariantCallingOutput
  .groupTuple(by: 2)
  .map {
    x ->  [
      x[0].get(0),  // the patient ID
      x[1].get(0),  // ID of the normal sample
      x[2],         // ID of the tumor sample (primary, relapse, whatever)
      x[4]          // list of VCF files
      ]
    }

  // we have to separate IDs and files
  collatedIDs = Channel.create()
  collatedFiles = Channel.create()
  tumorEntries = Channel.create()
  Channel
    .from filesToCollate
    .separate(collatedIDs, collatedFiles, tumorEntries) {x -> [ x, [x[0],x[1],x[2]], x[2] ]}

  (idPatient, idNormal) = getPatientAndNormalIDs(collatedIDs)
  println "Patient's ID: " + idPatient
  println "Normal ID: " + idNormal
  process concatFiles {
    publishDir outDir["Mutect1"]

    module 'bioinfo-tools'
    module 'java/sun_jdk1.8.0_40'

    cpus 1
    queue 'core'
    memory { params.singleCPUMem * task.attempt }
    time { params.runTime * task.attempt }

    input:
    set idT from tumorEntries

    output:
    file "MuTect1*.vcf"

    when: 'MuTect1' in workflowSteps

    script:
    """
    #!/bin/bash

    VARIANTS=`ls ${workflow.launchDir}/${outDir["Mutect1"]}/intervals_${idPatient}/*${idT}*.mutect1.vcf| awk '{printf(" -V %s \\\\n",\$1) }'`
    java -Xmx${task.memory.toGiga()}g -cp ${params.gatkHome}/GenomeAnalysisTK.jar org.broadinstitute.gatk.tools.CatVariants --reference ${refs["genomeFile"]} \$VARIANTS --outputFile MuTect1_${idPatient}_${idNormal}_${idT}.vcf
    """
  }
}

process RunMutect2 {
  publishDir outDir["MuTect2"] + "/intervals"

  cpus 1
  queue 'core'
  memory { params.singleCPUMem * task.attempt }
  time { params.runTime * task.attempt }

  input:
  set idPatient, idSampleNormal, file(bamNormal), file(baiNormal), idSampleTumor, file(bamTumor), file(baiTumor), genInt, gen_int from bamsFMT2

  output:
  set idPatient, idSampleNormal, idSampleTumor, val("${gen_int}_${idSampleNormal}_${idSampleTumor}"), file("${gen_int}_${idSampleNormal}_${idSampleTumor}.mutect2.vcf") into mutect2VariantCallingOutput

  // we are using MuTect2 shipped in GATK v3.6
  // TODO: the  "-U ALLOW_SEQ_DICT_INCOMPATIBILITY " flag is actually masking a bug in older Picard versions. Using the latest Picard tool
  // this bug should go away and we should _not_ use this flag
  // removed: -nct ${task.cpus} \
  when: 'MuTect2' in workflowSteps

  script:
  """
  #!/bin/bash
  java -Xmx${task.memory.toGiga()}g -jar ${params.gatkHome}/GenomeAnalysisTK.jar \
  -T MuTect2 \
  -R ${refs["genomeFile"]} \
  --cosmic ${refs["cosmic41"]} \
  --dbsnp ${refs["dbsnp"]} \
  -I:normal $bamNormal \
  -I:tumor $bamTumor \
  -U ALLOW_SEQ_DICT_INCOMPATIBILITY \
  -L \"${genInt}\" \
  -o ${gen_int}_${idSampleNormal}_${idSampleTumor}.mutect2.vcf
  """
}

if ('MuTect2' in workflowSteps) {

  // we are expecting one patient, one normal, and usually one, but occasionally more than one tumor
  // samples (i.e. relapses). The actual calls are always related to the normal, but spread across
  // different intervals. So, we have to collate (merge) intervals for each tumor case if there are
  // more than one. Therefore, what we want to do is to filter the multiple tumor cases into separate
  // channels and collate them according to their stage.
  mutect2VariantCallingOutput = mutect2VariantCallingOutput.view { it -> "Mutect2 output: $it" }
  filesToCollate = mutect2VariantCallingOutput
  .groupTuple(by: 2)
  .map {
    x ->  [
      x[0].get(0),  // the patient ID
      x[1].get(0),  // ID of the normal sample
      x[2],         // ID of the tumor sample (primary, relapse, whatever)
      x[4]          // list of VCF files
      ]
    }

  // we have to separate IDs and files
  collatedIDs = Channel.create()
  collatedFiles = Channel.create()
  tumorEntries = Channel.create()
  Channel
    .from filesToCollate
    .separate(collatedIDs, collatedFiles, tumorEntries) {x -> [ x, [x[0],x[1],x[2]], x[2] ]}

  (idPatient, idNormal) = getPatientAndNormalIDs(collatedIDs)
  println "Patient's ID: " + idPatient
  println "Normal ID: " + idNormal
  process concatFiles {
    publishDir outDir["MuTect2"]

    module 'bioinfo-tools'
    module 'java/sun_jdk1.8.0_40'

    cpus 1
    queue 'core'
    memory { params.singleCPUMem * task.attempt }
    time { params.runTime * task.attempt }

    input:
    set idT from tumorEntries

    output:
    file "MuTect2*.vcf"

    when: 'MuTect2' in workflowSteps

    script:
    """
    #!/bin/bash

    VARIANTS=`ls ${workflow.launchDir}/${outDir["Mutect2"]}/intervals/*${idT}*.mutect2.vcf| awk '{printf(" -V %s\\n",\$1) }'`
    java -Xmx${task.memory.toGiga()}g -cp ${params.gatkHome}/GenomeAnalysisTK.jar org.broadinstitute.gatk.tools.CatVariants -R ${refs["genomeFile"]}  \$VARIANTS -out MuTect2_${idPatient}_${idNormal}_${idT}.vcf
    """
  }
}

process VarDict {
  // we are doing the same trick for VarDictJava: running for the whole reference is a PITA, so we are chopping at repeats
  // (or centromeres) where no useful variant calls are expected
  publishDir outDir["VarDict"]

  // ~/dev/VarDictJava/build/install/VarDict/bin/VarDict -G /sw/data/uppnex/ToolBox/ReferenceAssemblies/hg38make/bundle/2.8/b37/human_g1k_v37_decoy.fasta -f 0.1 -N "tiny" -b "tiny.tumor__1.recal.bam|tiny.normal__0.recal.bam" -z 1 -F 0x500 -c 1 -S 2 -E 3 -g 4 -R "1:131941-141339"
  // we need further filters, but some of the outputs are empty files, confusing the VCF generator script

  cpus 1
  queue 'core'
  memory { params.singleCPUMem * task.attempt }
  time { params.runTime * task.attempt }

  input:
  set idPatient, idSampleNormal, file(bamNormal), file(baiNormal), idSampleTumor, file(bamTumor), file(baiTumor), genInt, gen_int from bamsFVD

  output:
  set idPatient, idSampleNormal, idSampleTumor, val("${gen_int}_${idSampleNormal}_${idSampleTumor}"), file("${gen_int}_${idSampleNormal}_${idSampleTumor}.VarDict.out") into varDictVariantCallingOutput

  when: 'VarDict' in workflowSteps

  script:
  """
  #!/bin/bash

  ${params.vardictHome}/vardict.pl -G ${refs["genomeFile"]} \
  -f 0.01 -N $bamTumor \
  -b "$bamTumor|$bamNormal" \
  -z 1 -F 0x500 \
  -c 1 -S 2 -E 3 -g 4 \
  -R ${genInt} > ${gen_int}_${idSampleNormal}_${idSampleTumor}.VarDict.out
  """
}

if ('VarDict' in workflowSteps) {

  // now we want to collate all the pieces of the VarDict outputs and concatenate the output files
  // so we can feed them into the somatic filter and the VCF converter

  varDictVariantCallingOutput = varDictVariantCallingOutput.view { it -> "VarDict output: $it" }
  (varDictVariantCallingOutput ,idPatient, idNormal, idTumor) = getPatientAndSample(varDictVariantCallingOutput)

  vdFilePrefix = idPatient + "_" + idNormal + "_" + idTumor
  vdFilesOnly = varDictVariantCallingOutput.map { x -> x.last()}

  resultsDir = file("${idPatient}.results")
  resultsDir.mkdir()

  process VarDictCollatedVCF {
    publishDir outDir["VarDict"]

    cpus 1
    queue 'core'
    memory { params.singleCPUMem * task.attempt }
    time { params.runTime * task.attempt }

    input:
    file vdPart from vdFilesOnly.toList()

    output:
    file(vdFilePrefix + ".VarDict.vcf")

    when: 'VarDict' in workflowSteps

    script:
    """
    #!/bin/bash

    for vdoutput in ${vdPart}
    do
      echo
      cat \$vdoutput | ${params.vardictHome}/testsomatic.R >> testsomatic.out
    done
    ${params.vardictHome}/var2vcf_somatic.pl -f 0.01 -N "${vdFilePrefix}" testsomatic.out > ${vdFilePrefix}.VarDict.vcf
    """
  }
}

process RunStrelka {
  publishDir outDir["Strelka"]

  time { params.runTime * task.attempt }

  input:
  set idPatient, idSampleNormal, file(bamNormal), file(baiNormal), idSampleTumor, file(bamTumor), file(baiTumor) from bamsForStrelka
  file refs["genomeFile"]
  file refs["genomeIndex"]

  output:
  set idPatient, val("${gen_int}_${idSampleNormal}_${idSampleTumor}"), file("strelka/results/*.vcf") into strelkaVariantCallingOutput

  when: 'Strelka' in workflowSteps

  script:
  """
  #!/bin/bash

  tumorPath=`readlink ${bamTumor}`
  normalPath=`readlink ${bamNormal}`
  ${params.strelkaHome}/bin/configureStrelkaWorkflow.pl \
  --tumor \$tumorPath \
  --normal \$normalPath \
  --ref ${refs["MantaRef"]} \
  --config ${params.strelkaCFG} \
  --output-dir strelka

  cd strelka

  make -j ${task.cpus}
  """
}

if ('Strelka' in workflowSteps) {
  strelkaVariantCallingOutput = strelkaVariantCallingOutput.view { it -> "Strelka output: $it" }
}

process Manta {
  publishDir outDir["Manta"]

  input:
    file refs["MantaRef"]
    file refs["MantaIndex"]
    set idPatient, idSampleNormal, file(bamNormal), file(baiNormal), idSampleTumor, file(bamTumor), file(baiTumor) from bamsForManta

  output:
   set idPatient, val("${idSampleNormal}_${idSampleTumor}"),file("${idSampleNormal}_${idSampleTumor}.somaticSV.vcf"),file("${idSampleNormal}_${idSampleTumor}.candidateSV.vcf"),file("${idSampleNormal}_${idSampleTumor}.diploidSV.vcf"),file("${idSampleNormal}_${idSampleTumor}.candidateSmallIndels.vcf")  into mantaVariantCallingOutput

  when: 'Manta' in workflowSteps

  //NOTE: Manta is very picky about naming and reference indexes, the input bam should not contain too many _ and the reference index must be generated using a supported samtools version.
  //Moreover, the bam index must be named .bam.bai, otherwise it will not be recognized
  script:
  """
  #!/bin/bash

  mv ${bamNormal} Normal.bam
  mv ${bamTumor} Tumor.bam

  mv ${baiNormal} Normal.bam.bai
  mv ${baiTumor} Tumor.bam.bai

  configManta.py --normalBam Normal.bam --tumorBam Tumor.bam --reference ${refs["MantaRef"]} --runDir MantaDir
  python MantaDir/runWorkflow.py -m local -j ${task.cpus}
  gunzip -c MantaDir/results/variants/somaticSV.vcf.gz > ${idSampleNormal}_${idSampleTumor}.somaticSV.vcf
  gunzip -c MantaDir/results/variants/candidateSV.vcf.gz > ${idSampleNormal}_${idSampleTumor}.candidateSV.vcf
  gunzip -c MantaDir/results/variants/diploidSV.vcf.gz > ${idSampleNormal}_${idSampleTumor}.diploidSV.vcf
  gunzip -c MantaDir/results/variants/candidateSmallIndels.vcf.gz > ${idSampleNormal}_${idSampleTumor}.candidateSmallIndels.vcf
  """
}

if ('Manta' in workflowSteps) {
  mantaVariantCallingOutput = mantaVariantCallingOutput.view { it -> "Manta output: $it" }
}

process alleleCount{
  //  #!/usr/bin/env nextflow
  // This module runs ascat preprocessing and run
  // Commands and code from Malin Larsson
  // Module based on Jesper Eisfeldt's code

  /* Workflow:
      First: run alleleCount on both normal and tumor (each its own process
      Second: Run R script to process allele counts into logR and BAF values
      Third: run ascat
  */

  // 1)
  // module load bioinfo-tools
  // module load alleleCount
  // alleleCounter -l /sw/data/uppnex/ToolBox/ReferenceAssemblies/hg38make/bundle/2.8/b37/1000G_phase3_20130502_SNP_maf0.3.loci -r /sw/data/uppnex/ToolBox/ReferenceAssemblies/hg38make/bundle/2.8/b37/human_g1k_v37_decoy.fasta -b sample.bam -o sample.allecount

  cpus 1
  queue 'core'
  memory { params.singleCPUMem * task.attempt }

  input:
  file refs["genomeFile"]
  file refs["genomeIndex"]
  file refs["acLoci"]
  // file normal_bam
  set idPatient, idSampleNormal, file(bamNormal), file(baiNormal), idSampleTumor, file(bamTumor), file(baiTumor) from bamsForAscat

  output:
  set idPatient, idSampleNormal, idSampleTumor, file("${idSampleNormal}.alleleCount"), file("${idSampleTumor}.alleleCount") into allele_count_output

  when: 'ascat' in workflowSteps

  script:
  """
  #!/bin/bash

  alleleCounter -l ${refs["acLoci"]} -r ${refs["genomeFile"]} -b ${bamNormal} -o ${idSampleNormal}.alleleCount;
  alleleCounter -l ${refs["acLoci"]} -r ${refs["genomeFile"]} -b ${bamTumor} -o ${idSampleTumor}.alleleCount;
  """
} // end process alleleCount

process convertAlleleCounts {
  // ascat step 2/3
  // converte allele counts
  // R script from Malin Larssons bitbucket repo:
  // https://bitbucket.org/malinlarsson/somatic_wgs_pipeline
  //
  // copyright?

  // prototype: "Rscript convertAlleleCounts.r tumorid tumorac normalid normalac gender"

  cpus 1
  queue 'core'
  memory { params.singleCPUMem * task.attempt }

  input:
  set idPatient, idSampleNormal, idSampleTumor, file(normalAlleleCt), file(tumorAlleleCt) from allele_count_output
  //file ${refs["scriptDir"]}/convertAlleleCounts.r

  output:
  set idPatient, idSampleNormal, idSampleTumor, file("${idSampleNormal}.BAF"), file("${idSampleNormal}.LogR"), file("${idSampleTumor}.BAF"), file("${idSampleTumor}.LogR") into convert_ac_output

  when: 'ascat' in workflowSteps

  script:
  """
  #!/bin/bash

  convertAlleleCounts.r ${idSampleTumor} ${tumorAlleleCt} ${idSampleNormal} ${normalAlleleCt} ${refs["gender"]}
  """


} // end process convertAlleleCounts

process runASCAT {
  // ascat step 3/3
  // run ascat
  // R scripts from Malin Larssons bitbucket repo:
  // https://bitbucket.org/malinlarsson/somatic_wgs_pipeline
  //
  // copyright?
  //
  // prototype: "Rscript run_ascat.r tumor_baf tumor_logr normal_baf normal_logr"

  cpus 1
  queue 'core'
  memory { params.singleCPUMem * task.attempt }

  input:
  set idPatient, idSampleNormal, idSampleTumor, file(normalBAF), file(normalLogR), file(tumorBAF), file(tumorLogR) from convert_ac_output

  output:
  file "ascat.done"

  when: 'ascat' in workflowSteps

  script:
  """
  #!/bin/env Rscript

  #######################################################################################################
  # Description:
  # R-script for converting output from AlleleCount to BAF and LogR values.
  #
  # Input:
  # AlleleCounter output file for tumor and normal samples
  # The first line should contain a header describing the data
  # The following columns and headers should be present:
  # CHR    POS     Count_A Count_C Count_G Count_T Good_depth
  #
  # Output:
  # BAF and LogR tables (tab delimited text files)
  #######################################################################################################

  source("$baseDir/scripts/ascat.R")

  tumorbaf = "${tumorBAF}"
  tumorlogr = "${tumorLogR}"
  normalbaf = "${normalBAF}"
  normallogr = "${normalLogR}"

  #Load the  data
  ascat.bc <- ascat.loadData(Tumor_LogR_file=tumorlogr, Tumor_BAF_file=tumorbaf, Germline_LogR_file=normallogr, Germline_BAF_file=normalbaf)

  #Plot the raw data
  ascat.plotRawData(ascat.bc)

  #Segment the data
  ascat.bc <- ascat.aspcf(ascat.bc)

  #Plot the segmented data
  ascat.plotSegmentedData(ascat.bc)

  #Run ASCAT to fit every tumor to a model, inferring ploidy, normal cell contamination, and discrete copy numbers
  ascat.output <- ascat.runAscat(ascat.bc)
  str(ascat.output)
  plot(sort(ascat.output\$aberrantcellfraction))
  plot(density(ascat.output\$ploidy))

  """
  // the following works when ascat.R is in the run_ascat.r file and the run_ascat.r file is in bin/
  //  run_ascat.r ${tumorBAF} ${tumorLogR} ${normalBAF} ${normalLogR}
  //  touch ascat.done

} // end process runASCAT

/*
 * add process for convert allele counts
 * add process for runASCAT.r
*/

process RunHaplotypeCaller {
  //HaplotypeCaller
  publishDir outDir["HaplotypeCaller"]

  cpus 1
  queue 'core'
  memory { params.singleCPUMem * task.attempt }
  time { params.runTime * task.attempt }

  input:
  set idPatient, idSampleNormal, file(bamNormal), file(baiNormal), genInt, gen_int from bamsFHC //Are these values mapped to bamNormal already?
  file refs["genomeFile"]
  file refs["genomeIndex"]

  output:
  set idPatient, idSampleNormal, val("${gen_int}_${idSampleNormal}"), file("${gen_int}_${idSampleNormal}.HC.vcf") into haplotypeCallerVariantCallingOutput

  when: 'HaplotypeCaller' in workflowSteps

  //parellelization information: "Many users have reported issues running HaplotypeCaller with the -nct argument, so we recommend using Queue to parallelize HaplotypeCaller instead of multithreading." However, it can take the -nct argument.
  script:
  """
  #!/bin/bash

  java -Xmx${task.memory.toGiga()}g -jar ${params.gatkHome}/GenomeAnalysisTK.jar \
  -T HaplotypeCaller \
  -R ${refs["genomeFile"]} \
  --dbsnp ${refs["dbsnp"]} \
  -I $bamNormal \
  -L \"${genInt}\" \
  -o ${gen_int}_${idSampleNormal}.HC.vcf
  """

}

if ('HaplotypeCaller' in workflowSteps) {
  haplotypeCallerVariantCallingOutput = haplotypeCallerVariantCallingOutput.view { it -> "HaplotypeCaller output: $it" }

  //Collate the vcf files (repurposed from mutect2 code)
  filesToCollate = haplotypeCallerVariantCallingOutput
  .groupTuple(by: 2)
  .map {
    x ->  [
      x[0].get(0),  // the patient ID
      x[1].get(0),  // ID of the normal sample
      x[4]          // list of VCF files
      ]
    }
  //groupTuple for my case (Example)
  //[tcga.cl, tcga.cl.normal__0, 3_93504854-198022430_tcga.cl.normal__0, /gulo/glob/seba/CAW_testrun/work/93/f103412ac2003254e902fa0d00f72c/3_93504854-198022430_tcga.cl.normal__0.HC.vcf]
  //x[0] <- tcga.cl
  //x[1] <- tcga.cl.normal__0
  //x[4] <- /gulo/glob/seba/CAW_testrun/work/93/f103412ac2003254e902fa0d00f72c/3_93504854-198022430_tcga.cl.normal__0.HC.vcf
  //    I am not sure what .get(0) does as it should reference the mapping in the tuple... like [name: 'Eva'] then .get('name')


  // we have to separate IDs and files
  collatedIDs = Channel.create()
  collatedFiles = Channel.create()
  normalEntries = Channel.create()
  Channel
    .from filesToCollate
    .separate(collatedIDs, collatedFiles, normalEntries) {x -> [ x, [x[0],x[1]], x[1] ]}

  (idPatient, idNormal) = getPatientAndNormalIDs(collatedIDs)
  println "Patient's ID: " + idPatient
  println "Normal ID: " + idNormal
  process concatFiles {
    publishDir outDir["HaplotypeCaller"]

    module 'bioinfo-tools'
    module 'java/sun_jdk1.8.0_92'

    cpus 1
    queue 'core'
    memory { params.singleCPUMem * task.attempt }
    time { params.runTime * task.attempt }

    input:
    set idN from normalEntries.unique()

    output:
    file "HaplotypeCaller*.vcf"

    script:
    """
    VARIANTS=`ls ${workflow.launchDir}/${outDir["HaplotypeCaller"]}/*${idN}*.HC.vcf| awk '{printf(" -V %s\\n",\$1) }'`
    java -Xmx${task.memory.toGiga()}g -cp ${params.gatkHome}/GenomeAnalysisTK.jar org.broadinstitute.gatk.tools.CatVariants -R ${refs["genomeFile"]}  \$VARIANTS -out HaplotypeCaller_${idPatient}_${idN}.vcf
    """
  }
}

/*
========================================================================================
=                                   F U N C T I O N S                                  =
========================================================================================
*/

def readPrefix (Path actual, template) {
  /*
   * Helper function, given a file Path
   * returns the file name region matching a specified glob pattern
   * starting from the beginning of the name up to last matching group.
   *
   * For example:
   *   readPrefix('/some/data/file_alpha_1.fa', 'file*_1.fa' )
   *
   * Returns:
   *   'file_alpha'
   */

  final fileName = actual.getFileName().toString()
  def filePattern = template.toString()
  int p = filePattern.lastIndexOf('/')
  if( p != -1 ) filePattern = filePattern.substring( p + 1 )
  if( !filePattern.contains('*') && !filePattern.contains('?') )
  filePattern = '*' + filePattern
  def regex = filePattern
    .replace('.', '\\.')
    .replace('*', '(.*)')
    .replace('?', '(.?)')
    .replace('{', '(?:')
    .replace('}', ')')
    .replace(',', '|')

  def matcher = (fileName =~ /$regex/)
  if ( matcher.matches() ) {
    def end = matcher.end( matcher.groupCount() )
    def prefix = fileName.substring(0,end)
    while ( prefix.endsWith('-') || prefix.endsWith('_') || prefix.endsWith('.') )
      prefix = prefix[0..-2]
    return prefix
  }
  return fileName
}

def copyChannel (channelToCopy) {
  daughterChannel1 = Channel.create()
  daughterChannel2 = Channel.create()
  Channel.from channelToCopy.separate(daughterChannel1, daughterChannel2) {a -> [a, a]}
  return [daughterChannel1, daughterChannel2]
}

def getPatientAndSample(aCh) {
  aCh = logChannelContent("Channel content: ", aCh)
  patientsCh = Channel.create()
  normalCh = Channel.create()
  tumorCh = Channel.create()
  originalCh = Channel.create()

  // get the patient ID
  // duplicate channel to get sample name
  Channel.from aCh.separate(patientsCh, normalCh, tumorCh, originalCh) {x -> [x,x,x,x]}

  // consume the patiensCh channel to get the patient's ID
  // we are assuming the first column is the same for the patient, as hoping
  // people do not want to compare samples from differnet patients
  idPatient = patientsCh.map { x -> [x.get(0)]}.unique().getVal()[0]
  // we have to close to make sure remainding items are not waiting
  patientsCh.close()

  idNormal = normalCh.map { x -> [x.get(1)]}.unique().getVal()[0]
  normalCh.close()

  idTumor = tumorCh.map { x -> [x.get(2)]}.unique().getVal()[0]
  tumorCh.close()

  return [ originalCh, idPatient, idNormal, idTumor]
}

def getPatientAndNormalIDs(aCh) {
  // TODO: merge the VarDict and the MuTect2 part
  patientsCh = Channel.create()
  normalCh = Channel.create()

  // get the patient ID
  // multiple the channel to get sample name
  Channel.from aCh.separate(patientsCh, normalCh) {x -> [x,x]}

  // consume the patiensCh channel to get the patient's ID
  // we are assuming the first column is the same for the patient, as hoping
  // people do not want to compare samples from differnet patients
  idPatient = patientsCh.map { x -> [x.get(0)]}.unique().getVal()[0]
  // we have to close to make sure remainding items are not waiting
  patientsCh.close()
  // something similar for the normal ID
  idNormal = normalCh.map { x -> [x.get(1)]}.unique().getVal()[0]
  normalCh.close()

  return [idPatient, idNormal]
}

/*
 * Information messages:
 */

workflow.onComplete {
  log.info "CANCER ANALYSIS WORKFLOW ~ $version - revision: $revision"
  log.info "Project     : ${workflow.projectDir}"
  log.info "workDir     : ${workflow.workDir}"
  log.info "Command line: ${workflow.commandLine}"
  log.info "Steps       : " + workflowSteps.join(", ")
  log.info "Completed at: ${workflow.complete}"
  log.info "Duration    : ${workflow.duration}"
  log.info "Success     : ${workflow.success}"
  log.info "Exit status : ${workflow.exitStatus}"
  log.info "Error report: ${workflow.errorReport ?: '-'}"
}

workflow.onError {
  log.info "Workflow execution stopped with the following message: ${workflow.errorMessage}"
}

def help_message(version, revision) {
  log.info "CANCER ANALYSIS WORKFLOW ~ $version - revision: $revision"
  log.info "    Usage:"
  log.info "       nextflow run SciLifeLab/CAW -c <file.config> --sample <sample.tsv> [--steps STEP[,STEP]]"
  log.info "    --steps"
  log.info "       Option to configure which processes to use in the workflow."
  log.info "         Different steps to be separated by commas."
  log.info "       Possible values are:"
  log.info "         preprocessing (default, will start workflow with FASTQ files)"
  log.info "         recalibrate (will start workflow with non-recalibrated BAM files)"
  log.info "         skipPreprocessing (will start workflow with recalibrated BAM files)"
  log.info "         MuTect1 (use MuTect1 for VC)"
  log.info "         MuTect2 (use MuTect2 for VC)"
  log.info "         VarDict (use VarDict for VC)"
  log.info "         Strelka (use Strelka for VC)"
  log.info "         HaplotypeCaller (use HaplotypeCaller for normal bams VC)"
  log.info "         Manta (use Manta for SV)"
  log.info "         ascat (use ascat for CNV)"
  log.info "    --help"
  log.info "       you're reading it"
  log.info "    --verbose"
  log.info "       Adds more verbosity to workflow"
  log.info "    --version"
  log.info "       displays version number"
}

def start_message(version, revision) {
  log.info "CANCER ANALYSIS WORKFLOW ~ $version - revision: $revision"
  log.info "Project     : ${workflow.projectDir}"
  log.info "Directory   : ${workflow.launchDir}"
  log.info "workDir     : ${workflow.workDir}"
  log.info "Steps       : " + workflowSteps.join(", ")
  log.info "Command line: ${workflow.commandLine}"
}

def version_message(version, revision) {
  log.info "CANCER ANALYSIS WORKFLOW"
  log.info "  version $version"
  log.info "  revision: $revision"
  log.info "Git info  : repository - $revision [$workflow.commitId]"
  log.info "Project   : ${workflow.projectDir}"
  log.info "Directory : ${workflow.launchDir}"
}

def grab_git_revision() {
  if ( workflow.commitId ) { // it's run directly from github
    return workflow.commitId.substring(0,10)
  }
  // Try to find the revision directly from git
  head_pointer_file = file("${baseDir}/.git/HEAD")
  if ( ! head_pointer_file.exists() ) {
    return ''
  }
  ref = head_pointer_file.newReader().readLine().tokenize()[1]
  ref_file = file("${baseDir}/.git/$ref")
  if ( ! ref_file.exists() ) {
    return ''
  }
  revision = ref_file.newReader().readLine()
  return revision.substring(0,10)
}

/*
 * Verify parameters and files existence:
 */

def checkRefExistence(referenceFile, fileToCheck) {
  try { assert file(fileToCheck).exists() }
  catch (AssertionError ae) {
    log.info  "Missing references: ${referenceFile} ${fileToCheck}"
    return false
  }
  return true
}

def checkStepExistence(step, stepsList) {
  try { assert stepsList.contains(step) }
  catch (AssertionError ae) {
    println("Unknown parameter: ${step}")
    return false
  }
  return true
}

def checkFileExistence(fileToCheck) {
  try { assert file(fileToCheck).exists() }
  catch (AssertionError ae) {
    exit 1, "Missing file in TSV file: ${fileToCheck}, see --help for more information"
  }
}

def extractFastqFiles(tsvFile) {
  /*
   * Channeling the TSV file containing FASTQ for preprocessing
   * The format is: "subject status sample lane fastq1 fastq2"
   * ie: HCC1954 0 HCC1954.blood HCC1954.blood_1 data/HCC1954.normal_S22_L001_R1_001.fastq.gz data/HCC1954.normal_S22_L001_R2_001.fastq.gz
   * I just added __status to the idSample so that the whole pipeline is still working without having to change anything.
   * I know, it is lazy...
   */
  fastqFiles = Channel
    .from(tsvFile.readLines())
    .map{ line ->
      list        = line.split()
      idPatient   = list[0]
      idSample    = "${list[2]}__${list[1]}"
      idRun       = list[3]
      fastqFile1  = file(list[4])
      fastqFile2  = file(list[5])

      checkFileExistence(fastqFile1)
      checkFileExistence(fastqFile2)

      [ idPatient, idSample, idRun, fastqFile1, fastqFile2 ]
    }
  return fastqFiles
}

def extractBamFiles(tsvFile) {
  /*
   * Channeling the TSV file containing BAM
   * The format is: "subject status sample bam bai"
   * ie: HCC1954 0 HCC1954.blood data/HCC1954.normal.bam HCC1954.normal.bai
   * Still with the __status added to the idSample
   */
  bamFiles = Channel
    .from(tsvFile.readLines())
    .map{ line ->
      list        = line.split()
      idPatient   = list[0]
      idSample    = "${list[2]}__${list[1]}"
      bamFile     = file(list[3])
      baiFile     = file(list[4])

      checkFileExistence(bamFile)
      checkFileExistence(baiFile)

      [ idPatient, idSample, bamFile, baiFile ]
    }
  return bamFiles
}