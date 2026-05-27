# NOTE:
# YOU MUST PASS IN ARGS FOR $file_id AND $fixitplus_language
# 
# Define a function to find only the sequences that are
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
      # First, DO NOT keep only patterns that repeat (group length > 1) because single-word repetition patterns can be a singular group
      select(length > 0)
      # OPERATE ONLY ON THINGS THAT REPEAT 3 TIMES OR MORE
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
              # Check if this group pattern consists of a single word, repeated 3 or more times
              ( ($group[$j].pattern|length > 2) and ($group[$j].pattern|unique|length == 1) )
              or
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

# data input is JSON object as output by ""http://apps.clams.ai/whisper-wrapper/v15" in document "http://mmif.clams.ai/vocabulary/VideoDocument/v1" wrapped in MMIF version "http://mmif.clams.ai/1.1.0"

.views[]|select(has("annotations") and (.annotations|type == "array") and (.annotations|length > 0)  )| [ .annotations[]|select(."@type"|(contains("/TextDocument/")|not)) ] as $annotations | [ $annotations[]|select(."@type"|startswith("http://mmif.clams.ai/vocabulary/Alignment") ).properties|pick(.source,.target) ] as $alignments | $alignments  | [ $annotations[]|select(.properties|has("word") or (.properties|has("text")) ).properties|pick(.word,.id) ] as $tokens | [ $annotations[]|select( (.properties|has("frameType")) and (.properties.frameType=="speech")).properties|pick(.start,.end,.id) |(.start, .end) |= ./1000 ] as $times | $times | [ $alignments[1:][]| .source as $tf | .target as $to | ( first($tokens[]|select(.id==$to)) + first($times[]|select(.id==$tf) ) | pick(.word,.start,.end) ) ]  as $wordjson

#### | $wordjson | find_only_contiguous_repeating_sequences  ## THIS BOGS DOWN ON VERY LARGE INPUT DATA SO FILTER OVERLAPPING CHUNKS BELOW


| $wordjson|length as $wordjsonlength
# analyze 300 words each iteration, to reprocess overlapping 100 between times
# [ resultarray,startnum,endnum,ismore]
| [ [] , 0 , 300 , true ]  
| [  while(.[3]==true ; [ .[1] as $start | .[2] as $end | .[0] + ( $wordjson[$start:$end ] | find_only_contiguous_repeating_sequences  )   ,(.[1]+200) , if (.[2]+200) >= $wordjsonlength then -1 else (.[2]+200) end , .[1] < $wordjsonlength  ]   )|.[0]] 
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
|  .parts|=$goodparts