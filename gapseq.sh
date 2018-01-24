#!/bin/bash

# TODO: dbhit: handle when $ec has more then one number
# TODO: handle incomplete/unspecific ecs from metacyc (e.g. get ec from kegg, update maually or get genes from metacyc)
# TODO: if taxonomic range is not bacteria, then sequence data must be updated!


usage()
{
    echo "Usage"
    echo "$0 -p keyword -f fasta [-d database] [-f model.sbml] [-o output.sbml] [-t taxonomy]"
    echo "  -p keywords such as pathways or susbstem (for example amino,nucl,cofactor,carbo,polyamine)"
    echo "  -d database (vmh,seed)]"
    echo "  -t taxonomic range (default: Bacteria)"
exit 1
}
# USAGE
#[ $# -ne 2 ] && { echo "Usage: $0 file.fasta model.sbml"; exit 1; }
#( [ $# -lt 2 ] || [ $# -gt 3 ] ) && { usage; }
#( [ $# -eq 3 ] ) && { withSbml=true; sbml=$(readlink -f $3); }


# paths and variables
curdir=$(pwd)
path=$(readlink -f "$0")
dir=$(dirname "$path")
seqpath=$dir/dat/seq/
bitcutoff=50 # cutoff blast: min bit score
metaPwy=$dir/dat/meta_pwy.tbl
metaRea=$dir/dat/meta_rea.tbl
reaDB1=$dir/dat/vmh_reactions.csv
reaDB2=$dir/dat/bigg_reactions.tbl
reaDB3=$dir/dat/seed_reactions.tsv
reaDB4=$dir/dat/mnxref_seed.tsv
brenda=$dir/dat/brenda_ec.csv
seedEC=$dir/dat/seed_Enzyme_Class_Reactions_Aliases_unique.tsv

pathways=""
input_sbml=""
output_sbml=""
database="seed"
verbose=0
taxonomy="Bacteria"

# tmp working directory
cd $(mktemp -d)

# A POSIX variable
OPTIND=1         # Reset in case getopts has been used previously in the shell.

while getopts "h?p:f:d:vi:o:t:" opt; do
    case "$opt" in
    h|\?)
        usage
        exit 0
        ;;
    p)  
        pathways=$OPTARG
        ;;
    f)  
        fasta=$(readlink -f $curdir/$OPTARG)
        [ ! -s $fasta ] && { echo Invalid file $OPTARG; exit 0; }
        ;;
    d)  
        database=$OPTARG
        ;;
    v)  
        verbose=1
        ;;
    i)  
        input_sbml=$(readlink -f $OPTARG)
        $dir/src/sbml_read.R $input_sbml
        ;;
    t)  
        taxonomy=$OPTARG
        ;;
    o)  
        output_sbml=$(readlink -f $OPTARG)
        ;;
    esac
done
shift $((OPTIND-1))
[ "$1" = "--" ] && shift


# pathways and fasta file have to be provided
( [ -z "$pathways" ] || [ -z "$fasta" ] ) && { usage; }

# select pathway keys to be used in database search
case $pathways in
    all)
        pwyKey=Pathways
        ;;
    amino)
        pwyKey=Amino-Acid-Biosynthesis
        ;;
    nucl)
        pwyKey=Nucleotide-Biosynthesis
        ;;
    cofactor)
        pwyKey=Cofactor-Biosynthesis
        ;;
    carbo)
        pwyKey=CARBO-BIOSYNTHESIS
        ;;
    carbo-deg)
        pwyKey=Carbohydrates-Degradation
        ;;
    polyamine)
        pwyKey=Polyamine-Biosynthesis
        ;;
    fatty)
        pwyKey=Fatty-acid-biosynthesis
        ;;
    energy)
        pwyKey=Energy-Metabolism
        ;;
    terpenoid)
        pwyKey=Terpenoid-Biosynthesis
        ;;
    degradation)
        pwyKey=Degradation
        ;;
    core)
        pwyKey="Amino-Acid-Biosynthesis|Nucleotide-Biosynthesis|Cofactor-Biosynthesis|Carbohydrates-Degradation|CARBO-BIOSYNTHESIS|Polyamine-Biosynthesis|Fatty-acid-biosynthesis|Energy-Metabolism|Terpenoid-Biosynthesis"
        ;;
    *)
        pwyKey=$pathways
        ;;
esac


# set databases
#[ "$1" == "all" ]       && pwyKey=Pathways
#[ "$1" == "amino" ]     && pwyKey=Amino-Acid-Biosynthesis
#[ "$1" == "nucl" ]      && pwyKey=Nucleotide-Biosynthesis
#[ "$1" == "cofactor" ]  && pwyKey=Cofactor-Biosynthesis
#[ "$1" == "carbo" ]     && pwyKey=CARBO-BIOSYNTHESIS
#[ "$1" == "carbo-deg" ]     && pwyKey=Carbohydrates-Degradation
#[ "$1" == "polyamine" ] && pwyKey=Polyamine-Biosynthesis
#[ "$1" == "fatty" ]     && pwyKey=Fatty-acid-biosynthesis
#[ "$1" == "energy" ]     && pwyKey=Energy-Metabolism
#[ "$1" == "terpenoid" ]     && pwyKey=Terpenoid-Biosynthesis
#[ "$1" == "degradation" ]     && pwyKey=Degradation
#[ "$1" == "core" ]      && pwyKey="Amino-Acid-Biosynthesis|Nucleotide-Biosynthesis|Cofactor-Biosynthesis|Carbohydrates-Degradation|CARBO-BIOSYNTHESIS|Polyamine-Biosynthesis|Fatty-acid-biosynthesis|Energy-Metabolism|Terpenoid-Biosynthesis"
#[ -z $pwyKey ] && pwyKey=$1


pwyDB=$(cat $metaPwy | grep -wE $pwyKey)
[ -z "$pwyDB" ] && { echo "No pathways found for key $pwyKey"; exit 1; }



# create blast database
makeblastdb -in $fasta -dbtype nucl -out orgdb >/dev/null


cand=""     #list of candidate reactions to be added
bestCand="" # list of candidates from (almost) complete pathways
bestPwy=""  # list of found pathways

pwyNr=$(echo "$pwyDB" | wc -l)
echo Checking for reaction from: $1 $pwyKey
echo Number of pathways to be considered: $pwyNr
for i in `seq 1 $pwyNr`
do
    pwyCand="" # candidate reaction of current pathway
    count=0
    countex=0
    countdb=0
    vague=0
    line=$(echo "$pwyDB" | awk -v i=$i 'NR==i')
    pwy=$(echo "$line" | awk -F "\t" '{print $1}')
    name=$(echo "$line" | awk -F "\t" '{print $2}')
    ecs=$(echo "$line" | awk -F "\t" '{print $7}')
    reaids=$(echo "$line" | awk -F "\t" '{print $6}')
    echo -e '\n'$i/$pwyNr: Checking for pathway $pwy $name
    for j in `seq 1 $(echo $ecs | tr "," "\n"i | wc -l)`
    #for ec in $(echo $ecs | tr "," "\n")
    do 
        ec=$(echo $ecs | awk -v j=$j -F ',' '{print $j}')
        rea=$(echo $reaids | awk -v j=$j -F ',' '{print $j}')
        re="([0-9]+.[0-9]+.[0-9]+.[0-9]+)"
        test=$(if [[ $ec =~ $re ]]; then echo ${BASH_REMATCH[1]}; fi) # check if not trunked ec number (=> too many hits)
        if [ -n "$test" ]; then
            ((count++))
            query=$seqpath$ec.fasta
            if [ ! -s $query ]; then
                python2 $dir/src/uniprot.py "$ec" "$taxonomy" # if sequence data not available then download from uniprot
            fi
            if [ -s $query ]; then
                out=$pwy-$ec.blast
                tblastn -db orgdb -query $query -outfmt '6 qseqid sseqid pident evalue bitscore stitle' >$out 
                if [ -s $out ]; then
                    bhit=$(cat $out | awk -v bitcutoff=$bitcutoff '$5>=bitcutoff {print $1}' | wc -l)
                    if [ $bhit -gt 0 ]; then
                        echo -e '\t'Blast hit: $rea $ec
                        
                        
                        kegg=$(grep -wF $rea $metaRea | awk -F "\t" {'print $5'})
                        altec=$(grep $ec $brenda | grep -P "([0-9]+.[0-9]+.[0-9]+.[0-9]+)" -o | grep -v $ec)
                        
                        # 1) search in reaction db by EC
                        if [ "$database" == "vmh" ]; then
                            dbhit=$(grep -wF $ec $reaDB1 | awk -F ',' '{print $1}')
                        elif [ "$database" == "seed" ]; then
                            dbhit=$(grep -wF $ec $seedEC | awk '{print $1}' | tr '|' '\n')
                            dbhit="$dbhit $(grep -wF $ec $reaDB4 | awk -F '\t' '{print $4}')"
                        fi

                        # 2) search in reaction db by kegg identifier 
                        if [ "$database" == "vmh" ]; then
                            [ -n "$kegg" ]  && dbhit="$dbhit $(grep -wE "$(echo $kegg |tr ' ' '|')" $reaDB1 | awk -F ',' '{print $1}')"
                        elif [ "$database" == "seed" ]; then
                            [ -n "$kegg" ] && dbhit="$dbhit $(grep -wE "$(echo $kegg | tr ' ' '|')" $reaDB3 | awk -F '\t' '$18 == "OK" {print $1}' )" # only consider reactions which are OK
                            [ -n "$kegg" ] && dbhit="$dbhit $(grep -wE "$(echo $kegg | tr ' ' '|')" $reaDB4 | awk -F '\t' '{print $4}')"
                        fi

                        # 3) search in reaction db by alternative EC
                        if [ "$database" == "vmh" ]; then
                            [ -n "$altec" ] && dbhit="$dbhit $(grep -wE "$(echo $altec | tr ' ' '|')" $reaDB1 | awk -F ',' '{print $1}')" # take care of multiple EC numbers
                        elif [ "$database" == "seed" ]; then
                            [ -n "$altec" ] && dbhit="$dbhit $(grep -wE "$(echo $altec | tr ' ' '|')" $seedEC | awk '{print $1}' | tr '|' '\n')" # take care of multiple EC numbers
                            [ -n "$altec" ] && dbhit="$dbhit $(grep -wE "$(echo $altec | tr ' ' '|')" $reaDB4 | awk -F '\t' '{print $4}')" # take care of multiple EC numbers
                        fi
                        
                        # 4) search in bigg db by metacyc id (does only make sense for vmh/bigg namespace)
                        if [ "$database" == "vmh" ]; then
                            dbhit="$dbhit $(grep -wF $rea $reaDB2 | awk '{print $1}')"
                        fi
                        
                        if [ -n "$dbhit" ]; then
                            dbhit="$(echo $dbhit | tr ' ' '\n' | sort | uniq | tr '\n' ' ')" # remove duplicates
                            echo -e '\t\t'Candidate reaction for import: $dbhit
                            pwyCand="$pwyCand$dbhit " # remember candidate reaction
                            ((countdb++))
                        else
                            echo -e '\t\t'No candidate reaction found for import: $rea $ec
                        fi
                        ((countex++))
                    else
                        echo -e '\t'No significant blast hits found for reaction: $rea $ec
                    fi
                else
                    echo -e '\t'No blast hits found for reaction: $rea $ec
                fi
            else
                echo -e '\t'No sequence data found for $rea $ec ..skipping..
               ((vague++))
            fi
        else
            #TODO: if unspecific should the reaction still be added?
            echo -e '\t'EC number too unspecific: $rea $ec ..skipping..
            ((vague++))
        fi
    done
    echo -e Pathway completness: $countex/$count with $vague reactions of unclear state
    echo -e Hits with candidate reactions in database: $countdb/$count
    cand="$cand$pwyCand "
    if [ $count -ne 0 ] && [ $(echo "scale=2; $countex/$count>=0.9" | bc) -ne 0 ]; then
        bestCand="$bestCand$pwyCand " # save candidates from almost complete (>=90%) pathways
        bestPwy="$bestPwy$name\n"
    fi
done

cand="$(echo $cand | tr ' ' '\n' | sort | uniq | tr '\n' ' ')" # remove duplicates
echo -e '\n'Total candidate reactions:
echo $cand

echo -e '\n'Pathways found:
echo -e $bestPwy

bestCand="$(echo $bestCand | tr ' ' '\n' | sort | uniq | tr '\n' ' ')" # remove duplicates
echo -e '\n'Candidate reactions from complete pathways:
echo -e $bestCand

# export found reactions 
#echo $bestCand > newReactions.lst
echo $cand > newReactions.lst
cp newReactions.lst $curdir/

# add reactions and write new sbml model
if [ -n "$input_sbml" ] ; then # if there is an xml file
    echo ""
    $dir/src/sbml_write.R newReactions.lst $dir
    modelold=$(basename $sbml)
    modelnew="${modelold%.*}G.xml"
    cp modelnew.xml $curdir/$modelnew
fi

