#!/usr/bin/env jq
# 
# recommended:  invoke this code using `jq -f /path/to/this/file` 
# works with either STDIN or filepath arg
#
# ASSUMES INPUT is a JSON array of objects that contain these properties or more {"word","start"}
#
# Here is a function to find only the sequences that are
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
  # consider using unique_by(.start)|unique_by(.end) when extraneous keys (e.g, "probability") are present

# ---
# To use the function, pipe your JSON array into it:
# find_only_contiguous_repeating_sequences
# ---
;

# NOTE:  HERE IS THE WHISPER-SPECIFIC DATA STRUCTURE ASSUMED OF INPUT
[.segments[].words] |[flatten[]|select((.start|tonumber) < (.end|tonumber))|pick(.word,.start,.end)] as $wordjson 

# but because it's too large to simply pass to the function, 
| $wordjson|length as $wordjsonlength
# analyze 300 words each iteration, to reprocess overlapping 100 between times
# [ resultarray,startnum,endnum,ismore]
| [ [] , 0 , 400 , true ] 
|  [ while(.[3] == true ;[ .[1] as $start | (if .[2] == -1 then .[-2] else .[2]-100 end ) as $end | .[0] + ( $wordjson[$start:$end ] | find_only_contiguous_repeating_sequences)  , .[1] + 200  , if .[2] + 200  >= $wordjsonlength then -1 else (.[2]+200) end, (.[2] + 200 ) <= $wordjsonlength  ] ) | .[0]]
| flatten | unique  as $json2remove

# create a modified version of $json2remove to impose "cleaner" white space
| [ $json2remove[]|.word=(.word|gsub("[^ ]";" ")) ] as $json2add
# substitute "cleaner" version of stammered sections
| $wordjson-$json2remove+$json2add 
# make sure everything is sorted correctly for use as transcript data 
| sort_by(.start)
# pipe this output to do phrase-level stuff for fixitplus consumption