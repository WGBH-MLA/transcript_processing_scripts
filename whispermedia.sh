#!/bin/bash -l 

# user launchagent runs periodically (adjust in plist file)
# it does sanity checks and exits noisily if the user lacks libraries
#  it exits quietly if it detects that a previous iteration of the script is still running
# this script runs on the mac and uses a docker container to perform audio speech recognition (ASR) 

 

helperMail="kevin_carter@wgbh.org";
helperURL="https://wiki.wgbh.org/x/6hTzC" ;

# ASR_IMAGE='wgbhmla/whisper:slim' ; # formatted as "repository/image:tag"
ASR_IMAGE=$(if [ "$(uname -m)" == 'arm64' ];then echo 'ghcr.io/wgbh-mla/whisper-bot:arm64-v0.2.0';else echo 'ghcr.io/wgbh-mla/whisper-bot:v0.2.0'; fi) ;
fixitplus_language='en-US'; # THIS APPEARS IN THE FINAL TRANSCRIPT JSON

whisper_language=' --language en ' ;
whisper_model=' --model small ' ;
whisper_threshold=' --no_speech_threshold 0.1 ' ;
whisper_word_timestamps=' --word_timestamps True ' ;
whisper_prompt=' ' # ' --initial_prompt "Buenos días. El siguiente programa fue producido en los estudios de WIPR. Muchas gracias al público radioyente por su atención." ';

whisper_opts="$whisper_language $whisper_model $whisper_threshold $whisper_word_timestamps $whisper_prompt" ; # ONLY THIS GETS USED BELOW

startupTimeout=45 ; #positive integer of seconds max for docker to launch 
mediadir=$(cd "$(dirname "$0")" && pwd -P) ;
myname=$(basename "$0") ;
containerNAMEfile="$mediadir"/containername.txt ; 
prefixfile="$mediadir"/s3keyprefix.txt ;

defaultS3prefix='cpb-aacip' ;
suspendS3prefix='_SUSPEND_' ; # CHANGE CONTENTS OF FILE TO SUSPEND FUTURE PROCESSING

s3profile='wgbh-mla' ;
s3resourcebucket='asr-rsrc';
s3listingbucket='asr-listing';
s3mediabucket='asr-media';
s3outputbucket='asr-dockerwhisper-output' ;
s3xfererrfile="$mediadir"/s3xfer.err ;
starttime="$(date +%s)" ;

callForHelp() {
        whatHelp=$1
        open "$helperURL"
        open "mailto:$helperMail?subject=help&su=help&cc=$USER@wgbh.org&body=$whatHelp"
}
#

# initialize local resource files 
touch "$containerNAMEfile" ;
touch "$prefixfile" ;
if [ ! -s "$prefixfile" ];
then printf %s "$defaultS3prefix" > "$prefixfile" ;
elif [ "$(head -1 "$prefixfile" )" == "$suspendS3prefix" ] ;
then exit ; # THIS IS HOW TO DISABLE WITHOUT UNINSTALLING 
fi 

thisS3prefix=$(cat "$prefixfile" ) ; # NOTES BELOW
#NOTE:  this permits use of foobar/ on S3 to permit coordinated prioritization of subsets
# ALSO:  see formulation of "$guid" for subdirectory naming

# BEGIN SANITY CHECKS

# sanity check to prevent multiple instances of this script running when another is just waiting for media to arrive
if [ "$(lsof "$mediadir"/"$myname" | grep -c '^bash' | awk '{print $1}')" -gt 1 ];
then 
    exit ;
fi

# sanity checks for system-level binaries
for utility in 'aws' 'docker' 'jq' ;
do
    if [ -z "$(which "$utility")" ] ;
    then 
        userChoice="$(osascript -e 'display dialog "Application \"'"$utility"'\" is needed but not found" with title "ERROR" with icon 0 buttons {"Help"} default button 1 giving up after 10' -e 'button returned of result')" ;
        if [ "$userChoice" == 'Help' ] ;
        then 
            callForHelp "I%20need%20%22$utility%22%20to%20be%20installed" ;
        fi ;
        exit ;
    fi ;
done

# sanity checks for aws stuff
for bucket in "$s3mediabucket" "$s3listingbucket" "$s3outputbucket";
do
    if [ -n "$(aws s3api head-bucket --profile $s3profile --bucket "$bucket" 2>&1 | grep -i '(\|forbid' )" ]
    then
        userChoice="$(osascript -e 'display dialog "Application \"aws\" cannot access a needed bucket: \"'$bucket'\"" with title "ERROR" with icon 0 buttons {"Help"} default button 1 giving up after 10' -e 'button returned of result')"
        if [ "$userChoice" == 'Help' ] 
        then
            callForHelp "I%20need%20aws-cli%20access%20to%20bucket%20$bucket"
        fi
    exit 
    fi
done

# open -a Docker >/dev/null 2>&1 &
# sanity checks for docker stuff 
until [ -n "$(pgrep docker)" ] 
do 
	open -a 'Docker Desktop' >/dev/null 2>&1 & 
	sleep 10;
done
unset dockerinfo ;

until [ "$dockerinfo" == "running" ]
# while [ -z "$(docker info 2>/dev/null)" ] 
do
	dockerinfo=$(docker desktop status --format json 2>/dev/null | jq -r '.Status' ) ;
	sleep 10
	nowtime="$(date +%s)"
	if [ "$(expr $nowtime - $starttime)" -gt "$startupTimeout" ] 
	then 
		userChoice="$(osascript -e 'display dialog "Application \"docker\" took too long to launch" with title "ERROR" with icon 0 buttons {"Help"} default button 1 giving up after 10' -e  'button returned of result')"
		if [ "$userChoice" == 'Help' ]
		then 
			callForHelp "Docker%20took%20too%20long%20to%20launch."
		fi ;
	exit ;
	fi ;
done

dockerinfo=$(docker info)
memunits=$(echo "$dockerinfo" | grep 'Total Memory:' | sed 's#^.*[0-9]##g'  | cut -c1 | tr '[[:lower:]]' '[[:upper:]]') ;
if [ "$(echo "$memunits" | tr -dC '[GTP]')" == "$memunits" ] ;
then 
    meminteger=$(echo "$dockerinfo" | grep 'Total Memory:' | tr -dC '[[0-9].]' | sed 's#\..*##g') ;
else 
    meminteger=0 ; # $memunits is not Gigabytes nor Terabytes nor Petabytes
fi
if [ "$meminteger" != 0 -a "$meminteger" -lt 6 -a "$memunits" != "G" ] ;
then 
    userChoice="$(osascript -e 'display dialog "Application \"docker\" preferences are misconfigured.  Allocate at least 6GB of memory for Kaldi ASR processing." with title "ERROR" with icon 0 buttons {"Help"} default button 1 giving up after 10' -e  'button returned of result')"
    if [ "$userChoice" == 'Help' ]
    then 
        callForHelp "Docker%20preferences%20for%20memory%20are%20misconfigured."
    fi ;
    exit ;
fi


# exit now if docker is still running a file 
# 
lastcontainerNAME=$(cat "$containerNAMEfile") ;
if [ ! -z "$lastcontainerNAME" ] ;
then 
    if [ ! -z "$(docker ps --no-trunc -f name="$lastcontainerNAME" | grep "$lastcontainerNAME" )" ] ;
    then 
        exit ;
    else 
        printf %s > "$containerNAMEfile" ;
#        break;
    fi ;
fi



# END OF SANITY CHECKS

# DOWNLOAD UPDATED VERSION OF THIS SCRIPT - IF AVAILABLE
latest_version_sig=$(aws s3api head-object --profile $s3profile --bucket "$s3resourcebucket" --key "$myname" 2>/dev/null | jq -r '.ETag|ltrimstr("\"")|rtrimstr("\"")' ) ;
my_version_sig=$(openssl dgst -md5 "$0" | awk -F\= '{print $2}' | awk '{print $1}') ;
if [ -n "$latest_version_sig" -a "$my_version_sig" != "$latest_version_sig" ];
then 
     echo 'AUTO-UPDATE ON'
    aws s3 cp --profile $s3profile s3://"$s3resourcebucket"/"$myname" - > "$mediadir"/"$myname"  ;
    exit ;
else 
    echo > /dev/null ;
fi 2>/dev/null ;

# upload any previous output products 
if [ -d "$mediadir"/transcripts_failed_upload ]
then 
    aws s3 cp --profile $s3profile --metadata ASR-operator="$USER" --recursive "$mediadir"/transcripts_failed_upload "s3://$s3outputbucket/" >> "$mediadir"/s3xfer.log && /bin/rm -rf "$mediadir"/transcripts_failed_upload ;
fi ;
if [ -d "$mediadir"/transcripts ] ;
then 
    # begin jq operations to create phrase-level versions of JSON for fixitplus
    IFS=$'\n\b' ; # because white space in idiotic file names 
    for tfile in $(ls -1 "$mediadir"/transcripts/"$defaultS3prefix"*.json 2>/dev/null );
    do
        guid=$(basename "$tfile" | sed 's#'"$defaultS3prefix"'.#'"$defaultS3prefix"'-#1' | tr '_.' '\n' | head -1) ;
#        "$mediadir"/vtt_2_fixit_json.sh "$tfile" | jq -r '[.parts[]|select((.end_time|tonumber) > (.start_time|tonumber))] as $goodparts  |  .parts|=$goodparts ' > "$mediadir"/transcripts/"$guid"'-transcript.json' ;
#        jq -r --arg fixitplus_language "$fixitplus_language" --arg tfile "$(basename "$tfile" .json)" '[foreach .segments[] as $item (0 ; . + 1 ; ($item.start|tostring|split(".")) as $start_array | ($item.end|tostring|split(".")) as $end_array | {"start_time":(($start_array[0]+"."+(($start_array[1]+"000")|.[0:3]))|tonumber),"end_time":(($end_array[0]+"."+(($end_array[1]+"000")|.[0:3]))|tonumber),"text":$item.text,"speaker_id":.} )] as $parts_array  | {"id": $tfile,"language": $fixitplus_language,"parts": $parts_array} | [.parts[]|select((.end_time|tonumber) > (.start_time|tonumber))] as $goodparts  |  .parts|=$goodparts ' "$tfile" > "$mediadir"/transcripts/"$guid"'-transcript.json' ;
#         jq -r --arg fixitplus_language "$fixitplus_language" --arg file_id "$(basename "$tfile" .json | sed 's#[_\.].*##1')" ' [{} + .segments[].words[]|{"start_time": ( (((.start|tostring) + ".")|split(".")[0] + ".") + ( ((.start|tostring) + ".")|split(".")[1]   + "00" | .[0:2]) )         , "end_time": ( (((.end|tostring) + ".")|split(".")[0] + ".") + ( ((.end|tostring) + ".")|split(".")[1]   + "00" | .[0:2]) ) , "word_group" : ( (((.start|tonumber) + ((.end - .start)|tonumber))/ 5 + 1)|tostring|split(".")[0]|tonumber ) , "word" : (.word|ltrimstr(" "))  }] as $word_json |  $word_json[0].start_time as $startoff | [$word_json[].word_group]|unique as $wgns | [ $wgns[] as $groupnum  |    [ $word_json[] |   select(.word_group==$groupnum ) ]   |   {start_time:.[0].start_time,end_time:.[-1].end_time , text:[.[].word]|join(" ")}   ] as $segments | [ foreach $segments[] as $item ( 0 ; . + 1 ; $item + {"speaker_id":.} )] | {"id":$file_id,"language":$fixitplus_language,"parts": . } | [.parts[]|select((.end_time|tonumber) > (.start_time|tonumber))] as $goodparts  |  .parts|=$goodparts '  "$tfile" > "$mediadir"/transcripts/"$guid"'-transcript.json' ;
         jq -r --arg fixitplus_language "$fixitplus_language" --arg file_id "$(basename "$tfile" .json | sed 's#[_\.].*##1')" '# Define a function to find only the sequences that are
# part of a contiguous (sequential) repeating run.
def find_only_contiguous_repeating_sequences:
  # Store the original array of objects and create an array of just the words
  . as $input
  | [.[].word] as $words
  | length as $n

  # 1. Generate all possible slices, storing their pattern, slice,
  #    start index (i), and length (L).
  | [
      range(2; $n + 1) as $L
      | range(0; $n - $L + 1) as $i
      | {
          "pattern": $words[$i : $i + $L],
          "slice": $input[$i : $i + $L],
          "i": $i,
          "L": $L
        }
    ]

  # 2. Group the generated objects by their "pattern"
  | group_by(.pattern)

  # 3. Filter the groups:
  | map(
      # First, keep only patterns that repeat (group length > 1)
      select(length > 1)
      # --- FIX IS HERE ---
      | . as $group     # Save the group array to a variable
      | .[0].L as $L    # Get the sequence length for this group
      # ---
      # Second, filter *inside* the group.
      # Keep only the members that have a contiguous neighbor.
      | [
          range(0; $group | length) as $j # Iterate over the group by index
          | $group[$j]                     # Get the current slice object
          | select(
              # Check if the *next* member (in $group) is contiguous
              ( ($group[$j+1].i // null) == (.i + $L) )
              or
              # Check if the *previous* member (in $group) was contiguous
              ( ($group[$j-1].i // null) == (.i - $L) )
            )
        ]
      # Per AAPB policy, exclude from output (to preserve) the first of every contiguous repeating sequence
        |.[1:]
    )

  # 4. Extract the "slice" (the array of objects) from each member
  #    of the remaining, filtered groups.
  | map(.[].slice)

  # 5. Flatten the result by one level to get the final array of arrays
  | flatten(1) | unique

# ---
# To use the function, pipe your JSON array into it:
# ---
;

# data input is JSON object as output by whisper-ai
[.segments[].words] |[flatten[]|select((.start|tonumber) < (.end|tonumber))|pick(.word,.start,.end)] as $wordjson 

| $wordjson|length as $wordjsonlength
# analyze 300 words each iteration, to reprocess overlapping 100 between times
# [ resultarray,startnum,endnum,ismore]
| [ [] , 0 , 400 , true ] 
# |  [ while(.[3] == true ;[ .[1] as $start | .[2] as $end | .[0] + ( $wordjson[$start:$end ] | find_only_contiguous_repeating_sequences)  , .[1] + 200  , if .[2] + 200  >= $wordjsonlength then -1 else (.[2]+200) end, (.[2] + 200 ) <= $wordjsonlength  ] ) | .[0]]
|  [ while(.[3] == true ;[ .[1] as $start | (if .[2] == -1 then .[-2] else .[2]-100 end ) as $end | .[0] + ( $wordjson[$start:$end ] | find_only_contiguous_repeating_sequences)  , .[1] + 200  , if .[2] + 200  >= $wordjsonlength then -1 else (.[2]+200) end, (.[2] + 200 ) <= $wordjsonlength  ] ) | .[0]]
| flatten | unique  as $json2remove


| [ $json2remove[]|.word=(.word|gsub("[^ ]";" ")) ] as $json2add
| $wordjson-$json2remove+$json2add 
| sort_by(.start)
# now do phrase-level stuff for fixitplus consumption
|  [{} + .[]|{"start_time": ( (((.start|tostring) + ".")|split(".")[0] + ".") + ( ((.start|tostring) + ".")|split(".")[1]   + "00" | .[0:2]) )         , "end_time": ( (((.end|tostring) + ".")|split(".")[0] + ".") + ( ((.end|tostring) + ".")|split(".")[1]   + "00" | .[0:2]) ) , "word_group" : ( (((.start|tonumber) + ((.end - .start)|tonumber))/ 5 + 1)|tostring|split(".")[0]|tonumber ) , "word" : (.word|ltrimstr(" "))  }] as $word_json 
|  $word_json[0].start_time as $startoff 
| [$word_json[].word_group]|unique as $wgns 
| [ $wgns[] as $groupnum  
| [ $word_json[] |   select(.word_group==$groupnum ) ]   
| {start_time:.[0].start_time,end_time:.[-1].end_time , text:[.[].word]|join(" ")}   ] as $segments 
| [ foreach $segments[] as $item ( 0 ; . + 1 ; $item + {"speaker_id":.} )] 
| {"id":$file_id,"language":$fixitplus_language,"parts": . } 
| [.parts[]|select((.end_time|tonumber) > (.start_time|tonumber))] as $goodparts  
|  .parts|=$goodparts'   "$tfile" > "$mediadir"/transcripts/"$guid"'-transcript.json' ;

	
## NOW GENERATE REPORT FILES
	if [ -f "$mediadir"/transcripts/"$guid"'-transcript.json' -a -s "$mediadir"/transcripts/"$guid"'-transcript.json' ]
	then
		tsfile="$mediadir"/transcripts/"$guid"'-transcript.json'
		max_segment_chars=$(jq -r '[.parts[].text|length]|sort[-1]' "$tsfile" )
	else
		tfile=$(ls -1 "$mediadir"/transcripts/"$defaultS3prefix"*.txt | head -1 )
		tsfile="$mediadir"'/transcripts/'"$guid"'-transcript.txt'
		touch "$tfile" "$tsfile"
		cp "$tfile" "$tsfile"
		max_segment_chars=$(wc -w "$tsfile")
	fi
	#	whisper_opts_json=$(echo '{"WHISPER OPTS":['"$(echo $whisper_opts | sed 's#\(\-\-[^ ]*\) *#"},{"option":"\1","value":"#g;s#$#"}#1;s# *\("\)#\1#g' | cut -c4-)"']}' | jq -r '.');
	#	VERSION IN SCRIPT CODE NEEDS TO ESCAPE CURLY BRACES IN `sed`
		whisper_opts_json=$(echo '{"WHISPER OPTS":['"$(echo $whisper_opts | sed 's#\(\-\-[^ ]*\) *#"\},\{"option":"\1","value":"#g;s#$#"\}#1;s# *\("\)#\1#g' | cut -c4-)"']}' | jq -r '.');
		words_count_json=$(echo '{"WORDS COUNT":['$(wc -w $(ls "$mediadir"/transcripts/*.txt ) | sed 's#^ *#,{"count":#1;s#^\([^ ]*\) *#\1,"item":"#1;s# *$#"}#1' | tr -d '\n' | cut -c2-  )']}' | jq -r '.') ;
		touch "$mediadir"/transcripts/stats.json ;
		stat_json=$(for f in $(ls -1 "$mediadir"/transcripts/*);
		do 
			eval "$(stat -s "$f")"; 
			path=$(echo "$(pwd -P)"/"$f"); 
			jq -n --arg st_dev "$st_dev" --arg st_ino "$st_ino" --arg st_mode "$st_mode" --arg st_nlink "$st_nlink" --arg st_uid "$st_uid" --arg st_gid "$st_gid" --arg st_rdev "$st_rdev" --arg st_size "$st_size" --arg st_atime "$st_atime" --arg st_mtime "$st_mtime" --arg st_ctime "$st_ctime" --arg st_birthtime "$st_birthtime" --arg st_blksize "$st_blksize" --arg st_blocks "$st_blocks" --arg st_flags "$st_flags" --arg path "$path" '{
		"st_dev": $st_dev,
		"st_ino": $st_ino,
		"st_mode": $st_mode,
		"st_nlink": $st_nlink,
		"st_uid": $st_uid,
		"st_gid": $st_gid,
		"st_rdev": $st_rdev,
		"st_size": $st_size,
		"st_atime": $st_atime,
		"st_mtime": $st_mtime,
		"st_ctime": $st_ctime,
		"st_birthtime": $st_birthtime,
		"st_blksize": $st_blksize,
		"st_blocks": $st_blocks,
		"st_flags": $st_flags,
		"path": $path}';
		done | jq -s '{"FILE SYSTEM METADATA":.}')
		
		fullreport=$(jq -n --argjson ffprobe_json "$(cat "$mediadir"/transcripts/stats.json)" --argjson whisper_opts_json "$whisper_opts_json" --argjson words_count_json "$words_count_json" --argjson stat_json "$stat_json" '[$ffprobe_json,$whisper_opts_json,$words_count_json,$stat_json]' 2>/dev/null)
		if [ -n "$fullreport" ] 
		then 
			echo "$fullreport" > "$mediadir"/transcripts/stats.json ;
			# now make variables for the report file named like 'cpb-aacip-b3f0b4c6bbe-tpme-20251112-003041-369983'
			tpme_date=$(date -j -f "%a %b %d %T %Z %Y" "$(date -r $(jq -r '.[]|select(has("FILE SYSTEM METADATA"))."FILE SYSTEM METADATA"[]|select( (.path|endswith("-transcript.json")) or (.path|endswith("-transcript.txt")) )."st_mtime"' "$mediadir"/transcripts/stats.json ))"  "+%Y-%m-%dT%H:%M:%S")
		else
			tpme_date=$(date -j -f "%a %b %d %T %Z %Y" "$(date -r "$tsfile")"  "+%Y-%m-%dT%H:%M:%S")
			echo "# WHISPER OPTS: $whisper_opts" >>  "$mediadir"/transcripts/errata.txt ;
			echo '# WORDS COUNT: ' >>  "$mediadir"/transcripts/errata.txt ; 
			echo "$max_segment_chars" >> "$mediadir"/transcripts/errata.txt ;
			echo '# FILE SYSTEM METADATA: ' >>  "$mediadir"/transcripts/errata.txt ; 
			stat "$mediadir"/transcripts/* >> "$mediadir"/transcripts/errata.txt ;
		fi
		# GENERATE THE TPME FILE
		jq -n --arg media_id "$guid" --arg transcript_id "$(basename "$tsfile")"  --arg parent_transcript_id "$(basename "$tfile")" --arg modification_date "$tpme_date" --arg max_segment_chars "$max_segment_chars" --arg application_name "$(basename "$0")" --arg application_version 'v1.2.3' '[{"media_id": $media_id,"transcript_id": $transcript_id,"parent_transcript_id": $parent_transcript_id,"modification_date": $modification_date,"provider": "GBH Archives","type": "transcript","file_format": "AAPB-transcript-JSON","features": {"time_aligned": true,"max_segment_chars": $max_segment_chars},"transcript_language": ["en"],"human_review_level": "machine-generated","application_type": "format-conversion","application_provider": "GBH Archives","application_name": "$application_name","application_version": $application_version,"application_repo": "https://github.com/WGBH-MLA/transcript_processing_scripts/tree/v1.2.3","application_params": [{"custom jq function": "find_only_contiguous_repeating_sequences"}],"processing_note": "word-level input is filtered to replace with white space all characters of word sequences (3 word minimum) repeated in at least 3 contiguous patterns; only the first such instance is preserved."}]' > "$mediadir"/transcripts/"$guid"'-tpme-'"$(echo "$tpme_date" | awk -FT '{print $1}' | tr -dC '[0-9]')"'-'"$(echo "$tpme_date" | awk -FT '{print $2}' | tr -dC '[0-9]')"'.json'
		
        mkdir -p "$mediadir"/transcripts/"$guid" ;
        find "$mediadir"/transcripts -maxdepth 1 -type f -exec mv {} "$mediadir"/transcripts/"$guid"/ ';' ;
    done

    #
    # begin upload of transcripts folder to s3
    printf %s > "$s3xfererrfile" ;
    aws s3 cp --profile $s3profile --metadata ASR-operator="$USER" --recursive "$mediadir"/transcripts "s3://$s3outputbucket/" >> "$mediadir"/s3xfer.log 2> "$s3xfererrfile" #### enable after testing ;
    if [ -s "$s3xfererrfile" ]
    then 
        mkdir -p "$mediadir"/transcripts_failed_upload ;
        cp -R "$mediadir"/transcripts/ "$mediadir"/transcripts_failed_upload && /bin/rm -rf "$mediadir"/transcripts && open "$mediadir"/transcripts_failed_upload ;
        open -e "$s3xfererrfile" ;
        callForHelp "completed%20transcripts%20failed%20to%20upload%20%20%28Include%20the%20error%20report%20now%21%29"
        # exit ; # no upload now but OK to try to download and do another
    else 
        /bin/rm -rf "$mediadir"/transcripts ##### enable after testing ;
        echo "transcripts uploaded ""$(date)" >> "$mediadir"/s3xfer.log ;
    fi
fi
# exit #### disable after testing

# tidy up when s3xfer.log > 1 MB
# the osascript call resolves to something like '/private/var/folders/63/1t13qp9x4bs019cr3_dsxjfhrc784f/T/TemporaryItems/'
if [ "$(du -k "$mediadir"/s3xfer.log | awk '{print $1}')" -gt 1000 ] ;
then 
    cat "$mediadir"/s3xfer.log | gzip - >> "$(osascript -e 'posix path of (path to temporary items folder)')"s3xfer.log.gz && printf %s > "$mediadir"/s3xfer.log ;
fi

# remove any media files assumed to be already-processed by the docker image
/bin/rm -f "$mediadir"/*.{wav,mp3,mp4,WAV,MP3,MP4} ;

# work the S3 until we get a file to process
while [ -z "$(ls "$mediadir"/*.{wav,mp3,mp4,WAV,MP3,MP4} 2>/dev/null)" ];
do 
    s3key='';
    while [ -z "$s3key" ] ;
    do 
        # get the first available listing from S3
        s3key=$(aws s3api list-objects --profile $s3profile --bucket "$s3listingbucket" --prefix "$thisS3prefix" --query 'Contents[0].Key' 2>/dev/null | jq -r '.|tostring' 2>/dev/null) ;
        if [ -z "$(echo $s3key | sed 's#^.*/##1')" ]; # reject any key that ends with '/'
        then 
            aws s3api delete-object --profile $s3profile --bucket "$s3listingbucket" --key "$s3key" ;
            s3key='';
        fi ;
    done 
    if [ "$s3key" == 'null' ] ;
    then
        osascript -e 'display dialog "No media to process are found on S3 using prefix \"'"$thisS3prefix"'\"" with title "ERROR" with icon 0 buttons {"Help"} default button 1 giving up after 10' -e 'button returned of result' >/dev/null 2>&1 & 
        exit ;
    fi 
    s3keyname=$(basename "$s3key") ;
    s3dir=$(dirname "$s3key" | sed 's#^[\./]*##1;s#/*$##1;s#[[:print:]]$#&/#1') ; # i.e., empty if not like foo/
    # now "move" the listing file out of the common view of $prefix
    aws s3api copy-object --profile $s3profile --copy-source "$s3listingbucket"/"$s3key" --bucket "$s3listingbucket" --key "$s3dir""processing"-"$s3keyname"-"$USER"-"$starttime" --metadata-directive COPY --tagging-directive COPY  &&  aws s3api delete-object --profile $s3profile --bucket "$s3listingbucket" --key "$s3key" ;
    #
    # make sure all that went OK!
    listing=$(aws s3api head-object --profile $s3profile --output text --bucket "$s3listingbucket" --key "$s3key" 2>/dev/null ) ;
    if [ ! -z "$listing" ]
    then
        exit ; # it is still there for some reason
    fi

    # now check for an eligible media file
    s3headvalue=$(aws s3api head-object --profile $s3profile --output text  --bucket "$s3mediabucket" --key "$s3keyname" 2>/dev/null ) ;
    if [ ! -z "$s3headvalue" ] ;
    then 
        # check to see if & how the media file is tagged; 
        # a mismatch could suggest either an interrupted session by this user or a race condition with another user 
        #
#       begin jq work 
        s3tagsvalues=$(aws s3api get-object-tagging --profile $s3profile --bucket "$s3mediabucket" --key "$s3keyname" ) ;
        s3tagvalue=$(echo $s3tagsvalues | jq -r '.TagSet[]|select(.Key=="ASR-operator").Value') ;
        s3othertags=$(echo "$s3tagsvalues" | jq -r '.TagSet|map(select(.Key!="ASR-operator"))' ) ;
#       end jq work


        if [ -z "$s3tagsvalues" ] ;
        then 
            aws s3api put-object-tagging --profile $s3profile --bucket "$s3mediabucket" --key "$s3keyname" --tagging 'TagSet=[{Key=ASR-operator,Value='"$USER"'}]' ;
        elif [ -z "$s3tagvalue" -a ! -z "$s3othertags" ] 
        then 
#           aws s3api put-object-tagging --profile $s3profile --bucket "$s3mediabucket" --key "$s3key" --tagging 'TagSet=[{Key=ASR-operator,Value='"$USER"'},'"$s3othertags"']' ;
            newtagset=$(echo "$s3othertags" | jq -r --arg USER "$USER" --argjson s3othertags "$s3othertags" '.+[{"Key":"ASR-operator","Value":$USER}] | {"TagSet":.}') ;
            aws s3api put-object-tagging --profile $s3profile --bucket "$s3mediabucket" --key "$s3keyname" --tagging "$newtagset" ;
        fi
        s3tagvalue=$(aws s3api get-object-tagging --profile $s3profile --output text  --bucket "$s3mediabucket" --key "$s3keyname" --query "TagSet[?Key=='ASR-operator'].Value") ;
        if [ "$s3tagvalue" == "$USER" ] ; 
        then 
            mkdir -p "$mediadir"/transcripts ;
#            aws s3 cp --profile $s3profile s3://"$s3mediabucket"/"$s3keyname" "$mediadir"/"$s3keyname" && docker run --rm -v "$mediadir"/:/mymedia/ "$ASR_IMAGE" /bin/bash -c "ffprobe -hide_banner -pretty /mymedia/'$s3keyname' 2>&1 " > "$mediadir"/transcripts/stats.txt && echo "$starttime" > "$containerNAMEfile" && eval nice docker run  --name "$starttime" --rm -d -v "$mediadir"/:/mymedia/ -v $HOME/.cache/whisper/:/root/.cache/whisper/ "$ASR_IMAGE" whisper $whisper_opts --output_dir /mymedia/transcripts/ /mymedia/"$s3keyname"  >/dev/null ;
            aws s3 cp --profile $s3profile s3://"$s3mediabucket"/"$s3keyname" "$mediadir"/"$s3keyname" && docker run --rm -v "$mediadir"/:/mymedia/ "$ASR_IMAGE" /bin/bash -c "ffprobe -v quiet -print_format json -show_entries 'format=filename,nb_streams,nb_stream_groups,format_name,start_time,size,duration,bit_rate : format_tags : stream=index,id,language,codec_type,profile,codec_tag_string,codec_tag,pix_fmt,field_order,width,height,sample_aspect_ratio,display_aspect_ratio,bit_rate,avg_frame_rate,r_frame_rate,time_base,sample_rate,channel_layout,channels,sample_fmt,bit_rate : stream_tags :error' -i /mymedia/'$s3keyname' " > "$mediadir"/transcripts/stats.json && echo "$starttime" > "$containerNAMEfile" && eval nice docker run  --name "$starttime" --rm -d -v "$mediadir"/:/mymedia/ -v $HOME/.cache/whisper/:/root/.cache/whisper/ "$ASR_IMAGE" whisper $whisper_opts --output_dir /mymedia/transcripts/ /mymedia/"$s3keyname"  >/dev/null ;
            break;
        else 
            aws s3api copy-object --profile $s3profile --bucket "$s3listingbucket" --copy-source "$s3listingbucket"/"$s3dir"processing-"$s3keyname"-"$USER"-"$starttime" --key "$s3dir"error-tagging-"$s3keyname"-"$USER"-"$starttime" --metadata-directive COPY --tagging-directive COPY ;
            aws s3api delete-object --profile $s3profile --bucket "$s3listingbucket" --key "$s3dir"processing-"$s3keyname"-"$USER"-"$starttime" ;
                # "something unexpected went wrong is now recorded as an error in the listings"
        fi
    else 
        aws s3api copy-object --profile $s3profile --bucket "$s3listingbucket" --copy-source "$s3listingbucket"/"$s3dir"processing-"$s3keyname"-"$USER"-"$starttime" --key "$s3dir"error-missing-"$s3keyname" --metadata-directive COPY --tagging-directive COPY ;
        aws s3api delete-object --profile $s3profile --bucket "$s3listingbucket" --key "$s3dir"processing-"$s3keyname"-"$USER"-"$starttime" ;
    fi
    sleep 30; # in case nothing could be had from S3 
done 

