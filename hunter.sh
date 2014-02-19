#!/bin/bash
#
# This program takes a fastq file as input, then it runs several tools
# to filter, decontaminate and then blast reads to viral database.
# Finally, it writes files of taxonomy and summary statistics

VERSION=0.2.0
LOCKFILE="pipeline_version.lock"
FILEIN=$1
DEC_OUT_NAME=decon_out
FASTAFILE=processed.fasta

OWNDIR=$(dirname $(readlink -f "$BASH_SOURCE"))

KMER=11  # default=11
GLOBAL=1  # 0:local, 1:global
MATCH=75
THRESHDECONCOV=90
THRESHDECONID=94

prinseq() { /usr/local/bin/prinseq-lite.pl "$@"; }
deconseq() { $OWNDIR/deconseq.pl "$@"; }
tax_orgs() { $OWNDIR/tax_orgs.py "$@"; }
victor() { $OWNDIR/victor.py "$@"; }

if [ -f $LOCKFILE ] ; then
	echo 'pipeline lock file exists'
	exit
else
	echo "$VERSION" > $LOCKFILE
fi

echo 'Pipeline version' $VERSION
echo 'Analysing file' $1

# Counts the reads correctly even if the file is gzipped
if [[ $FILEIN == *fastq ]];
	then
	echo 'here'
	NREADS=`wc -l $FILEIN | cut -f 1 -d " "`
elif [[ $FILEIN == *fastq.gz ]];
	then
	echo 'there'
	NREADS=`gunzip -c $FILEIN | wc -l | cut -f 1 -d " "`
fi

let "NREADS /= 4"
echo 'Reads to analyze:' $NREADS
	
echo `date`
echo 'cleaning with seqtk'
seqtk trimfq $FILEIN | seqtk seq -L 75 - > intermediate.fastq
echo ''

INTREADS=`wc -l intermediate.fastq | cut -f 1 -d " "`
let "INTREADS /= 4"
echo 'Reads passing seqtk:' $INTREADS
# We want to split in 16 processors, so each file has at most
# (NREADS / 16) + 1 reads and 4 times as many lines
let "MAX_READS_PER_FILE = INTREADS / 16"
let "MAX_READS_PER_FILE += 1"
let "MAX_L = MAX_READS_PER_FILE * 4"
echo 'Max lines per file is:' $MAX_L

split -l $MAX_L -d intermediate.fastq splitted

find . -name "splitted*" | xargs -I % mv % %.fastq
rm intermediate.fastq


echo `date`
echo 'cleaning with prinseq'
seq -w 0 15 | xargs -P 0 -I {} /usr/local/bin/prinseq-lite.pl \
	    -fastq splitted{}.fastq -lc_method entropy -lc_threshold 70 \
        -log prinseq{}.log -min_qual_mean 20 -ns_max_p 25 \
		-out_good ./good{} -out_bad ./bad{}
echo ''

cat good??.fastq > good.fastq
cat bad??.fastq > bad.fastq
cat prinseq??.log > prinseq.log
seq -w 0 15 | xargs -I {} rm splitted{}.fastq good{}.fastq bad{}.fastq \
	prinseq{}.log


echo `date`
echo 'decontaminating from human, bacterial, bovine with victor'
victor -r good.fastq -d human -d bact1 -d bact2 -d bact3 -d bos -d dog \
	-o ${DEC_OUT_NAME}
echo ''

seqret ${DEC_OUT_NAME}_clean.fastq fasta::$FASTAFILE

echo `date`
echo 'running blast'
blastn -query $FASTAFILE -db /data/databases/rins_viral_blast_db \
-perc_identity 75 -max_target_seqs 1 -num_threads 24 \
-outfmt  '6 qseqid sseqid pident length mismatch gapopen qstart qend sstart send' > results.tsv

echo `date`
echo 'extracting unique high-scoring segment pairs (HSP)'
echo 'qseqid sseqid pident length mismatch gapopen qstart qend sstart send' > unique.tsv
sort -k1,1 -u results.tsv >> unique.tsv

echo `date`
echo 'listing organisms'
tax_orgs unique.tsv

echo 'summary statistics'
echo 'total_reads,passing_quality,from_human,from_bacteria,from_bos_taurus,from_canis,clean,matching_viral_db' > stats.csv

PASS_READS=`wc -l good.fastq | cut -f 1 -d " "`
let "PASS_READS /= 4"

H_READS=$(grep -v '^@\w\w' good_human.sam | cut -f 1 | sort -u | wc -l)
BAC1_READS=$(grep -v '^@\w\w' good_human_bact1.sam | cut -f 1 | sort -u | wc -l)
BAC2_READS=$(grep -v '^@\w\w' good_human_bact1_bact2.sam | cut -f 1 | sort -u | wc -l)
BAC3_READS=$(grep -v '^@\w\w' good_human_bact1_bact2_bact3.sam | cut -f 1 | sort -u | wc -l)
BOS_READS=$(grep -v '^@\w\w' good_human_bact1_bact2_bact3_bos.sam | cut -f 1 | sort -u | wc -l)
DOG_READS=$(grep -v '^@\w\w' good_human_bact1_bact2_bact3_bos_dog.sam | cut -f 1 | sort -u | wc -l)
let "BAC_READS = BAC1_READS + BAC2_READS + BAC3_READS"

CLEAN_READS=`grep -c ">" processed.fasta`
VIR_READS=`wc -l unique.tsv | cut -f 1 -d " "`
let "VIR_READS -= 1"
echo $NREADS,$PASS_READS,$H_READS,$BAC_READS,$BOS_READS,$DOG_READS,$CLEAN_READS,$VIR_READS >> stats.csv

echo 'cleaning and zipping'
gzip good.fastq
rm bad.fastq good_*.fastq
gzip decon_out_clean.fq

for SAMFILE in good_human good_human_bact1 good_human_bact1_bact2 \
	good_human_bact1_bact2_bact3 good_human_bact1_bact2_bact3_bos \
		good_human_bact1_bact2_bact3_bos_dog
do
	samtools view -Su ${SAMFILE}.sam | samtools sort - ${SAMFILE}_sorted
	rm ${SAMFILE}.sam
done

echo ''
echo -e "\033[1;31m===========================================================\033[0m"
echo ''
