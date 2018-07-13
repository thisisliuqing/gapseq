#!/bin/bash

# TODO: metacyc superpathways seems to be incomplete e.g. ASPASN-PWY
# TODO: limit pwy search to taxonomic scope
# TODO: save dummy seq file for ec without uniprot hit (save nonsense requests)
# TODO: handle incomplete/unspecific ecs from metacyc (e.g. get ec from kegg, update maually or get genes from metacyc)
# TODO: if taxonomic range is not bacteria, then sequence data must be updated!

pathways=""
database="seed"
pwyDatabase="metacyc"
verbose=0
taxonomy="Bacteria"
bitcutoff=50 # cutoff blast: min bit score
identcutoff=0   # cutoff blast: min identity
covcutoff=75 # cutoff blast: min coverage
strictCandidates=false
completnessCutoff=66 # consider pathway to be present if other hints (e.g. key enzyme present) are avaiable and pathway completness is at least as high as completnessCutoff (requires strictCandidates=false)
completnessCutoffNoHints=80 # consider pathway to be present if no hints are avaiable (requires stricCandidates=false)
blast_format="qseqid pident evalue bitscore qcovs stitle sstart send sseq"
blast_back=false
noSuperpathways=false
vagueCutoff=0.3 # cutoff for vague reactions. If the amount of vague reactions in a pathways is more then this their influence will not be recognized even with strictCandidates=false

usage()
{
    echo "Usage"
    echo "$0 -p keyword / -e ec [-d database] [-t taxonomy] file.fasta."
    echo "  -p keywords such as pathways or subsystems (for example amino,nucl,cofactor,carbo,polyamine)"
    echo "  -e search by ec numbers (comma separated)"
    echo "  -d database: vmh or seed (default: $database)"
    echo "  -t taxonomic range for sequences to be downloaded (default: $taxonomy)"
    echo "  -b bit score cutoff for local alignment (default: $bitcutoff)"
    echo "  -i identity cutoff for local alignment (default: $identcutoff)"
    echo "  -c coverage cutoff for local alignment (default: $covcutoff)"
    echo "  -s strict candidate reaction handling (do _not_ use pathway completness, key kenzymes and operon structure to infere if imcomplete pathway could be still present (default: $strictCandidates)"
    echo "  -u suffix used for output files (default: pathway keyword)"
    echo "  -a blast hits back against uniprot enzyme database"
    echo "  -n Do not consider superpathways of metacyc database"
    echo "  -l Select the pathway database (MetaCyc, KEGG, SEED, all; default: $pwyDatabase)"
exit 1
}


# paths and variables
curdir=$(pwd)
path=$(readlink -f "$0")
dir=$(dirname "$path")
uniprotIdentity=0.9 # clustered uniprot database (0.5 or 0.9)
metaPwy=$dir/dat/meta_pwy.tbl
keggPwy=$dir/dat/kegg_pwy.tbl
seedPwy=$dir/dat/seed_pwy.tbl
metaRea=$dir/dat/meta_rea.tbl
reaDB1=$dir/dat/vmh_reactions.csv
reaDB2=$dir/dat/bigg_reactions.tbl
reaDB3=$dir/dat/seed_reactions.tsv
reaDB4=$dir/dat/mnxref_seed.tsv
brenda=$dir/dat/brenda_ec.csv
seedEC=$dir/dat/seed_Enzyme_Class_Reactions_Aliases_unique_edited.tsv


# A POSIX variable
OPTIND=1         # Reset in case getopts has been used previously in the shell.

while getopts "h?p:e:d:i:b:c:vst:snou:al:" opt; do
    case "$opt" in
    h|\?)
        usage
        exit 0
        ;;
    p)  
        pathways=$OPTARG
        ;;
    e)  
        ecnumber=$OPTARG
        ;;
    d)  
        database=$OPTARG
        ;;
    v)  
        verbose=1
        ;;
    b)
        bitcutoff=$OPTARG
        ;;
    i)
        identcutoff=$OPTARG
        ;;
    c)
        covcutoff=$OPTARG
        ;;
    t)  
        taxonomy=$OPTARG
        ;;
    s)
        strictCandidates=true
        ;;
    u)
        output_suffix=$OPTARG
        ;;
    a)
        blast_back=true
        ;;
    n)
        noSuperpathways=true
        ;;
    l)
        pwyDatabase=$OPTARG
        ;;
    esac
done
shift $((OPTIND-1))
[ "$1" = "--" ] && shift

# after parsing arguments, only fasta file shoud be there
[ "$#" -ne 1 ] && { usage; }

# get fasta file
fasta=$(readlink -f "$1")
[[ ! -s $fasta ]] && { echo Invalid file: $1; exit 0; }
tmpvar=$(basename $fasta)
fastaID="${tmpvar%.*}"

# pathways or ec number as well as fasta file have to be provided
( [ -z "$pathways" ] && [ -z "$ecnumber" ] ) || [ -z "$fasta" ]  && { usage; }

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
        pwyKey="Amino-Acid-Biosynthesis|Nucleotide-Biosynthesis|Cofactor-Biosynthesis|Carbohydrates-Degradation|CARBO-BIOSYNTHESIS|Polyamine-Biosynthesis|Fatty-acid-biosynthesis|Energy-Metabolism|Terpenoid-Biosynthesis|Chorismate-Biosynthesis"
        ;;
    kegg)
        pwyKey=kegg
        ;;
    *)
        pwyKey=$pathways
        ;;
esac


# squence directory
seqpath=$dir/dat/seq/$taxonomy/unipac$(printf %.0f $(echo "$uniprotIdentity * 100" | bc -l))
mkdir -p $seqpath

# tmp working directory
cd $(mktemp -d)


if [ -n "$ecnumber" ]; then
    # create dummpy pwy template for given ec number
    pwyKey=$ecnumber
    pwyDB=$(echo -e "dummy\t$ecnumber\t\t\t\t$ecnumber\t$ecnumber")
    pathways="ec"
else
    pwyDatabase=$(echo $pwyDatabase | tr '[:upper:]' '[:lower:]')
    # get entries for pathways from databases
    if [[ "$pwyDatabase" == "all" ]]; then
        cat $metaPwy $keggPwy $seedPwy > allPwy
    elif [[ "$pwyDatabase" == "metacyc" ]]; then
        cat $metaPwy > allPwy
    elif [[ "$pwyDatabase" == "kegg" ]]; then
        cat $keggPwy > allPwy
    elif [[ "$pwyDatabase" == "seed" ]]; then
        cat $seedPwy > allPwy
    fi
    pwyDB=$(cat allPwy | grep -wEi $pwyKey)
    [[ "$noSuperpathways" = true ]] && pwyDB=$(echo "$pwyDB" | grep -v 'Super-Pathways')
    [ -z "$ecnumber" ] && [ -z "$pwyDB" ] && { echo "No pathways found for key $pwyKey"; exit 1; }
fi
[ -z "$output_suffix" ] && output_suffix=$pathways


# function to get database hits for ec number
getDBhit(){
    kegg=$(grep -wF $rea $metaRea | awk -F "\t" {'print $5'})
    altec=$(grep -wF $ec $brenda | grep -P "([0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+)" -o | grep -v $ec)
    
    # 1) search in reaction db by EC
    if [ "$database" == "vmh" ]; then
        dbhit=$(grep -wF $ec $reaDB1 | awk -F ',' '{print $1}')
    elif [ "$database" == "seed" ]; then
        dbhit=$(grep -wF $ec $seedEC | awk -F '\t' '{print $1}' | tr '|' ' ')
        dbhit="$dbhit $(grep -wF $ec $reaDB4 | awk -F '\t' '{print $4}' | tr '\n' ' ')"
    fi

    # 2) search in reaction db by kegg identifier 
    if [ "$database" == "vmh" ]; then
        [ -n "$kegg" ]  && dbhit="$dbhit $(grep -wE "$(echo $kegg |tr ' ' '|')" $reaDB1 | awk -F ',' '{print $1}')"
    elif [ "$database" == "seed" ]; then
        [ -n "$kegg" ] && dbhit="$dbhit $(grep -wE "$(echo $kegg | tr ' ' '|')" $reaDB3 | awk -F '\t' '$18 == "OK" {print $1}' )" # only consider reactions which are OK
        [ -n "$kegg" ] && dbhit="$dbhit $(grep -wE "$(echo $kegg | tr ' ' '|')" $reaDB4 | awk -F '\t' '{print $4}' | tr '\n' ' ')"
    fi

    # 3) search in reaction db by alternative EC
    if [ "$database" == "vmh" ]; then
        [ -n "$altec" ] && dbhit="$dbhit $(grep -wE "$(echo $altec | tr ' ' '|')" $reaDB1 | awk -F ',' '{print $1}')" # take care of multiple EC numbers
    elif [ "$database" == "seed" ]; then
        [ -n "$altec" ] && dbhit="$dbhit $(grep -wE "$(echo $altec | tr ' ' '|')" $seedEC | awk -F '\t' '{print $1}' | tr '|' ' ')" # take care of multiple EC numbers
        [ -n "$altec" ] && dbhit="$dbhit $(grep -wE "$(echo $altec | tr ' ' '|')" $reaDB4 | awk -F '\t' '{print $4}')" # take care of multiple EC numbers
    fi
    
    # 4) search in bigg db by metacyc id (does only make sense for vmh/bigg namespace)
    if [ "$database" == "vmh" ]; then
        dbhit="$dbhit $(grep -wF $rea $reaDB2 | awk '{print $1}')"
    fi

    [ "$dbhit" == " " ] && dbhit=""
}





# create blast database
makeblastdb -in $fasta -dbtype nucl -out orgdb >/dev/null


cand=""     #list of candidate reactions to be added
bestPwy=""  # list of found pathways
echo -e "ID\tName\tPrediction\tCompleteness\tVagueReactions\tKeyReactions\tKeyReactionsFound\tReactionsFound" > output.tbl # pahtway statistics file

pwyNr=$(echo "$pwyDB" | wc -l)
echo Checking for pathways and reactions in: $1 $pwyKey
echo Number of pathways to be considered: $pwyNr
for i in `seq 1 $pwyNr`
do
    pwyCand="" # candidate reaction of current pathway
    pwyVage="" # reaction belonging to trunked EC numbers (no sequence blast possible..)
    pwyNoHitFound="" # remember reactions without blast hit so that they can be added in case of high pathway completness 
    count=0
    countex=0
    countexList="" # list with reactions ids found
    countdb=0
    vague=0
    keyReaFound=""
    vagueKeyReaFound=""
    line=$(echo "$pwyDB" | awk -v i=$i 'NR==i')
    pwy=$(echo "$line" | awk -F "\t" '{print $1}')
    name=$(echo "$line" | awk -F "\t" '{print $2}')
    ecs=$(echo "$line" | awk -F "\t" '{print $7}')
    reaids=$(echo "$line" | awk -F "\t" '{print $6}')
    reaNames=$(echo "$line" | awk -F "\t" '{print $9}')
    keyRea=$(echo "$line" | awk -F "\t" '{print $8}' | tr ',' ' ')
    pwyHierarchy=$(echo "$line" | awk -F "\t" '{print $4}' | sed 's/|\|THINGS\|Generalized-Reactions\|Pathways\|FRAMES//g' | sed 's/,,//g')
    echo -e '\n'$i/$pwyNr: Checking for pathway $pwy $name
    echo "($pwyHierarchy)"
    for j in `seq 1 $(echo $ecs | tr "," "\n" | wc -l)`
    #for ec in $(echo $ecs | tr "," "\n")
    do 
        ec=$(echo $ecs | awk -v j=$j -F ',' '{print $j}')
        rea=$(echo $reaids | awk -v j=$j -F ',' '{print $j}')
        reaName=$(echo $reaNames | awk -v j=$j -F ';' '{print $j}')
        re="([0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+)"
        EC_test=$(if [[ $ec =~ $re ]]; then echo ${BASH_REMATCH[1]}; fi) # check if not trunked ec number (=> too many hits)
        is_exception=$(grep -Ew "$ec|$reaName" $dir/dat/exception.tbl | wc -l)
        if [[ $is_exception -gt 0 ]] && [[ $identcutoff -lt 70 ]];then # take care of similair enzymes with different function
            identcutoff_tmp=70
            echo -e "\tUsing higher identity cutoff for $rea"
        else
            identcutoff_tmp=$identcutoff
        fi
        ((count++))
        if [[ -n "$EC_test" ]]; then
            getDBhit # get db hits for this reactions
            query=$seqpath/$ec.fasta
            if [ ! -f "$query" ]; then # check if sequence is not available => try to download
                echo -e '\t'Downloading sequence for: $ec 
                $dir/src/uniprot.sh -e "$ec" -t "$taxonomy" -i $uniprotIdentity >/dev/null
            fi
        fi
        # if no EC number is available or no sequence was found for EC number then use reaction name instead for sequence search
        if [[ -z "$EC_test" ]] || [[ ! -s "$query" ]] ;then
            reaNameHash=$(echo -n "$reaName" | md5sum | awk '{print $1}')
            query="$seqpath/$reaNameHash.fasta"
            if [ ! -f "$query" ]; then # check if sequence is not available => try to download
                echo -e '\t'Downloading sequence for: $reaName "\n\t\t(hash: $reaNameHash)" 
                $dir/src/uniprot.sh -r "$reaName" -t "$taxonomy" -i $uniprotIdentity >/dev/null
            fi
        fi
        if [ -s "$query" ]; then
            out=$rea.blast #$ec.blast
            if [ ! -f $out ]; then # check if there is a former hit
                csplit -s -z "$query" '/>/' '{*}' # split multiple fasta file and skip further testing if a significant hit is found
                for q in `ls xx*`
                do
                    tblastn -db orgdb -query $q -outfmt "6 $blast_format" >> $out 
                    bhit=$(cat $out | awk -v bitcutoff=$bitcutoff -v identcutoff=$identcutoff_tmp -v covcutoff=$covcutoff '{if ($2>=identcutoff && $4>=bitcutoff && $5>=covcutoff) print $0}')
                    if [ -n "$bhit" ]; then
                        break
                    fi
                done
                rm xx*
            fi
            if [ -s $out ]; then
                bhit=$(cat $out | awk -v bitcutoff=$bitcutoff -v identcutoff=$identcutoff_tmp -v covcutoff=$covcutoff '{if ($2>=identcutoff && $4>=bitcutoff && $5>=covcutoff) print $0}')
                if [ -n "$bhit" ]; then
                    bestIdentity=$(echo "$bhit" | sort -rgk 4,4 | head -1 | cut -f2)
                    bestBitscore=$(echo "$bhit" | sort -rgk 4,4 | head -1 | cut -f4)
                    bestCoverage=$(echo "$bhit" | sort -rgk 4,4 | head -1 | cut -f5)
                    besthit_all=$(echo "$bhit" | sort -rgk 4,4 | head -1)
                    echo -e "$rea\t$ec\t$besthit_all" >> reactions.tbl 
                    echo -e '\t'Blast hit: $rea $reaName $ec"\n\t\tbit=$bestBitscore, id=$bestIdentity, cov=$bestCoverage"
                    # check if key reactions of pathway
                    if [[ $keyRea = *"$rea"* ]]; then
                        echo -e '\t\t--> KEY reaction found <--'
                        keyReaFound="$keyReaFound $rea"
                    fi
                    #blast hit back to uniprot enzyme database
                    if [ "$blast_back" = true ]; then
                        echo "$bhit" | sort -rgk 4,4 | head -1 | cut -f9 | sed 's/-/*/g' > "$ec.hit.fasta"
                        echo "Blast best hit against uniprot db:"
                        blastp -db $dir/dat/seq/uniprot_sprot -query "$ec.hit.fasta" -outfmt '6 pident bitscore qcovs stitle' | awk '{if ( $4>50 ) print $0}' | sort -rgk 2,2 | head -n 3
                    fi
                    
                    if [ -n "$dbhit" ]; then
                        dbhit="$(echo $dbhit | tr ' ' '\n' | sort | uniq | tr '\n' ' ')" # remove duplicates
                        echo -e '\t\t'Candidate reaction for import: `echo "$dbhit" | wc -w`
                        pwyCand="$pwyCand$dbhit " # remember candidate reaction
                        ((countdb++))
                    else
                        echo -e '\t\t'NO candidate reaction found for import
                    fi
                    ((countex++))
                    countexList="$countexList$rea "
                else
                    someIdentity=$(cat $out | sort -rgk 4,4 | head -1 | cut -f2)
                    someBitscore=$(cat $out | sort -rgk 4,4 | head -1 | cut -f4)
                    someCoverage=$(cat $out | sort -rgk 4,4 | head -1 | cut -f5)
                    somehit_all=$( cat $out | sort -rgk 4,4 | head -1)
                    echo -e "$rea\t$ec\t$somehit_all" >> reactions.tbl 
                    echo -e '\t'NO good blast hit: $rea $reaName $ec"\n\t\t(best one: id=$someIdentity bit=$someBitscore cov=$someCoverage)"
                    if [[ -n "$dbhit" ]];then
                        dbhit="$(echo $dbhit | tr ' ' '\n' | sort | uniq | tr '\n' ' ')" # remove duplicates
                        pwyNoHitFound="$pwyNoHitFound$dbhit "
                    fi
                fi
            else
                echo -e '\t'NO blast hit: $rea $reaName $ec
                [[ -n "$EC_test" ]] && getDBhit
                if [[ -n "$dbhit" ]];then
                    dbhit="$(echo $dbhit | tr ' ' '\n' | sort | uniq | tr '\n' ' ')" # remove duplicates
                    pwyNoHitFound="$pwyNoHitFound$dbhit "
                fi
            fi
        else
            echo -e "\tNO sequence data found for $rea $reaName $ec ..skipping.."
            echo -e "\t\t$(basename $query)" 
            ((vague++))
            [[ -n "$EC_test" ]] && getDBhit
            [[ -n "$dbhit" ]] && pwyVage="$pwyVage$dbhit "
            [[ $keyRea = *"$rea"* ]] && vagueKeyReaFound="$vagueKeyReaFound $rea"
        fi
        [[ verbose -gt 0 ]] && echo -e "\t\tCandidate reactions: $dbhit"
    done # pathway
    
    if [ $count -eq 0 ]; then
        completness=0
    else
        check_vague=$(echo "$vague < $count*$vagueCutoff" | bc) # vague reactions shouldn't make more than certain amount of total reactions
        if [ "$strictCandidates" = false ] && [ $check_vague -eq 1 ] ; then # if vague reaction are considered they should not influence the completness treshold
            completness=$(echo "scale=0; 100*($countex+$vague)/$count" | bc)
        else
            completness=$(echo "scale=0; 100*($countex)/$count" | bc)
        fi
    fi
    if [ $vague -eq 0 ] || [ "$strictCandidates" = true ] || [ $check_vague -eq 0 ]; then
        echo "Pathway completness: $countex/$count ($completness%)"
    else
        echo "Pathway completness: ($countex+$vague)/$count ($completness%) with $vague reactions of unclear state"
    fi

    echo -e Hits with candidate reactions in database: $countdb/$count
    if [ -n "$keyReaFound" ]; then
        CountKeyReaFound=$(echo $keyReaFound | tr ' ' '\n' |  sort | uniq | wc -l)
    else
        CountKeyReaFound=0
    fi
    
    CountTotalKeyRea=$(echo $keyRea | wc -w)
    CountTotalVagueKeyRea=$(echo $vagueKeyReaFound | wc -w)
    if [[ "$strictCandidates" = false ]] && [[ $CountTotalVagueKeyRea -gt 0 ]]; then
        echo Key reactions: "$CountKeyReaFound/($CountTotalKeyRea-$CountTotalVagueKeyRea) with $CountTotalVagueKeyRea key reactions of unclear state"
        CountTotalKeyRea=$(echo $CountTotalKeyRea - $CountTotalVagueKeyRea | bc )
    else
        echo Key reactions: $CountKeyReaFound/$CountTotalKeyRea
    fi
    
    prediction=false
    # add reactions of pathways (even if no blast hit) if above treshold (and no key enzyme is missed)
    cand="$cand$pwyCand " # add all reactions with direct sequence-based evidence
    if [[ $CountTotalKeyRea -gt 0 ]]; then 
        KeyReaFracAvail=$(echo "scale=2; $CountKeyReaFound / $CountTotalKeyRea > 0.5" | bc) # how many key enzymes were found?
    else
        KeyReaFracAvail=1 # no key enzymes are present anyway
    fi

    
    # A) Consider as complete pathway because all reactions are present
    if [[ $completness -eq 100 ]]; then
        prediction=true
        bestPwy="$bestPwy$name\n"
    # B) Consider as complete pathway because of completness treshold (key enzymes should be present too)
    elif [[ $completness -ge $completnessCutoffNoHints ]] && [[ "$KeyReaFracAvail" -eq 1 ]] && [[ "$strictCandidates" = false ]]; then
        echo "Consider pathway to be present because of completness treshold!"
        prediction=true
        cand="$cand$pwyVage$pwyNoHitFound "
        bestPwy="$bestPwy$name ($completness% completness, added because of treshhold)\n"
    # C) Consider as complete pathway because of key enzymes (lower treshold)
    elif [[ $CountKeyReaFound -ge 1 ]] && [[ $CountKeyReaFound -eq $CountTotalKeyRea ]] && [[ $completness -ge $completnessCutoff ]] && [[ "$strictCandidates" = false ]]; then
        echo "Consider pathway to be present because of key enzyme!"
        prediction=true
        cand="$cand$pwyVage$pwyNoHitFound "
        bestPwy="$bestPwy$name ($completness% completness, added because of key enzyme)\n"
    fi
    
    echo -e "$pwy\t$name\t$prediction\t$completness\t$vague\t$CountTotalKeyRea\t$CountKeyReaFound\t$countexList" >> output.tbl # write down some statistics

done

cand="$(echo $cand | tr ' ' '\n' | sort | uniq | tr '\n' ' ')" # remove duplicates
if [[ verbose -gt 0 ]]; then
    echo -e '\n'Total candidate reactions:
    echo $cand
fi

echo -e '\n'Pathways found:
echo -e $bestPwy


# export found reactions 
echo -e Candidate reactions found: $(echo "$cand" | wc -w) '\n'
echo $cand > newReactions.lst
cp newReactions.lst $curdir/${fastaID}-$output_suffix-Reactions.lst
cp output.tbl $curdir/${fastaID}-$output_suffix-Pathways.tbl
[ -f reactions.tbl ] && echo "#rxn ec $(echo $blast_format | tr ' ' '\t')" | cat - reactions.tbl | awk '!a[$0]++' > $curdir/${fastaID}-$output_suffix-blast.tbl # add header and remove duplicates


ps -p $$ -o %cpu,%mem,cmd
times
