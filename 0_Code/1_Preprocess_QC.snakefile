################################################################################
################################################################################
################################################################################
# EHI snakefile for preprocessing raw reads (trimming/mapping to host)
# Raphael Eisenhofer 4/2022
#         .----------------.  .----------------.  .----------------.
#        | .--------------. || .--------------. || .--------------. |
#        | |  _________   | || |  ____  ____  | || |     _____    | |
#        | | |_   ___  |  | || | |_   ||   _| | || |    |_   _|   | |
#        | |   | |_  \_|  | || |   | |__| |   | || |      | |     | |
#        | |   |  _|  _   | || |   |  __  |   | || |      | |     | |
#        | |  _| |___/ |  | || |  _| |  | |_  | || |     _| |_    | |
#        | | |_________|  | || | |____||____| | || |    |_____|   | |
#        | |              | || |              | || |              | |
#        | '--------------' || '--------------' || '--------------' |
#         '----------------'  '----------------'  '----------------'
################################################################################
################################################################################
################################################################################

### Setup sample inputs
import os
from glob import glob

SAMPLE = [os.path.basename(fn).replace("_R1.fastq.gz", "")
            for fn in glob(f"2_Reads/1_Untrimmed/*_R1.fastq.gz")]

print("Detected the following samples:")
print(SAMPLE)

################################################################################
### Setup the desired outputs
rule all:
    input:
        expand("3_Outputs/1_QC/2_CoverM/{sample}_coverM_mapped_host.tsv", sample=SAMPLE)
################################################################################
### Preprocess the reads using fastp
rule fastp:
    input:
        r1i = "2_Reads/1_Untrimmed/{sample}_R1.fastq.gz",
        r2i = "2_Reads/1_Untrimmed/{sample}_R2.fastq.gz"
    output:
        r1o = "2_Reads/2_Trimmed/{sample}_trimmed_1.fastq.gz",
        r2o = "2_Reads/2_Trimmed/{sample}_trimmed_2.fastq.gz",
        fastp_html = "2_Reads/3_fastp_results/{sample}.html",
        fastp_json = "2_Reads/3_fastp_results/{sample}.json"
    conda:
        "1_Preprocess_QC.yaml"
    threads:
        8
    benchmark:
        "3_Outputs/0_Logs/{sample}_fastp.benchmark.tsv"
    log:
        "3_Outputs/0_Logs/{sample}_fastp.log"
    message:
        "Using FASTP to trim adapters and low quality sequences for {wildcards.sample}"
    shell:
        """
        fastp \
            --in1 {input.r1i} --in2 {input.r2i} \
            --out1 {output.r1o} --out2 {output.r2o} \
            --trim_poly_g \
            --trim_poly_x \
            --n_base_limit 5 \
            --qualified_quality_phred 20 \
            --length_required 60 \
            --thread {threads} \
            --html {output.fastp_html} \
            --json {output.fastp_json} \
            --adapter_sequence AGATCGGAAGAGCACACGTCTGAACTCCAGTCA \
            --adapter_sequence_r2  AGATCGGAAGAGCGTCGTGTAGGGAAAGAGTGT \
        &> {log}
        """
################################################################################
## Index host genomes:
rule index_ref:
    input:
        "1_References"
    output:
        bt2_index = "1_References/CattedRefs.fna.gz.rev.2.bt2l",
        catted_ref = "1_References/CattedRefs.fna.gz"
    conda:
        "1_Preprocess_QC.yaml"
    threads:
        40
    log:
        "3_Outputs/0_Logs/host_genome_indexing.log"
    message:
        "Concatenating and indexing host genomes with Bowtie2"
    shell:
        """
        # Concatenate input reference genomes
        cat {input}/*.gz > {input}/CattedRefs.fna.gz

        # Index catted genomes
        bowtie2-build \
            --large-index \
            --threads {threads} \
            {output.catted_ref} {output.catted_ref} \
        &> {log}
        """
################################################################################
### Map samples to host genomes, then split BAMs:
rule map_to_ref:
    input:
        r1i = "2_Reads/2_Trimmed/{sample}_trimmed_1.fastq.gz",
        r2i = "2_Reads/2_Trimmed/{sample}_trimmed_2.fastq.gz",
        catted_ref = "1_References/CattedRefs.fna.gz",
        bt2_index = "1_References/CattedRefs.fna.gz.rev.2.bt2l"
    output:
        all_bam = "3_Outputs/1_QC/1_BAMs/{sample}.bam",
        host_bam = "3_Outputs/1_QC/1_Host_BAMs/{sample}_host.bam",
        non_host_r1 = "2_Reads/4_Host_removed/{sample}_M_1.fastq",
        non_host_r2 = "2_Reads/4_Host_removed/{sample}_M_2.fastq",
    conda:
        "1_Preprocess_QC.yaml"
    threads:
        20
    benchmark:
        "3_Outputs/0_Logs/{sample}_mapping.benchmark.tsv"
    log:
        "3_Outputs/0_Logs/{sample}_mapping.log"
    message:
        "Mapping {wildcards.sample} reads to host genomes"
    shell:
        """
        # Map reads to catted reference using Bowtie2
        bowtie2 \
            --time \
            --threads {threads} \
            -x {input.catted_ref} \
            -1 {input.r1i} \
            -2 {input.r2i} \
        | samtools view -b -@ {threads} - | samtools sort -@ {threads} -o {output.all_bam} - &&

        # Extract non-host reads (note we're not compressing for nonpareil)
        samtools view -b -f12 -@ {threads} {output.all_bam} \
        | samtools fastq -@ {threads} -1 {output.non_host_r1} -2 {output.non_host_r2} - &&

        # Send host reads to BAM
        samtools view -b -F12 -@ {threads} {output.all_bam} \
        | samtools sort -@ {threads} -o {output.host_bam} -
        """
################################################################################
### Estimate diversity and required sequencing effort using nonpareil
rule nonpareil:
    input:
        non_host_r1 = "2_Reads/4_Host_removed/{sample}_M_1.fastq",
        non_host_r2 = "2_Reads/4_Host_removed/{sample}_M_2.fastq",
    output:
        npo = "3_Outputs/1_QC/3_nonpareil/{sample}.npo"
    params:
        sample = "3_Outputs/1_QC/3_nonpareil/{sample}"
    conda:
        "1_Preprocess_QC.yaml"
    threads:
        10
    benchmark:
        "3_Outputs/0_Logs/{sample}_nonpareil.benchmark.tsv"
    message:
        "Estimating microbial diversity using nonpareil"
    shell:
        """
        #Run nonpareil
        nonpareil \
            -s {input.non_host_r1} \
            -f fastq \
            -t {threads} \
            -b {params.sample}

        #Compress reads
        pigz -p {threads} {input.non_host_r1}
        pigz -p {threads} {input.non_host_r2}
        """
################################################################################
### Calculate % of each sample's reads mapping to host genome/s
rule coverM:
    input:
        "3_Outputs/1_QC/1_BAMs/{sample}.bam"
    output:
        "3_Outputs/1_QC/2_CoverM/{sample}_coverM_mapped_host.tsv"
    params:
        assembly = "1_References/CattedRefs.fna.gz"
    conda:
        "1_Preprocess_QC.yaml"
    threads:
        40
    benchmark:
        "3_Outputs/0_Logs/{sample}_coverM.benchmark.tsv"
    log:
        "3_Outputs/0_Logs/{sample}_coverM.log"
    message:
        "Calculating percentage of reads mapped to host genome/s using coverM"
    shell:
        """
        #Calculate % mapping to host using coverM
        coverm genome \
            -b {input} \
            -s _ \
            -m relative_abundance \
            -t {threads} \
            --min-covered-fraction 0 \
            > {output}
        """
################################################################################
onsuccess:
    shell("""
            mail -s "workflow completed" raph.eisenhofer@gmail.com < {log}

            #Clean up files
            rm 3_Outputs/1_QC/1_BAMs/*/*.bam
          """)
