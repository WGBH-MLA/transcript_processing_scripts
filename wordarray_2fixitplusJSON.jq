#!/usr/bin/env jq
# 
# recommended:  invoke this code using `jq -f /path/to/this/file` 
# works with either STDIN or filepath arg
#
# ASSUMES INPUT is a JSON array of objects that contain these properties or more {"word","start","end"}
# REQUIRES INVOCATION WITH ARGS `file_id` and `fixitplus_language`
# output is phrase-level fixitplus-format JSON
#
# build word groupd in 5 sec. segments
[{} + .[]|{"start_time": ( (((.start|tostring) + ".")|split(".")[0] + ".") + ( ((.start|tostring) + ".")|split(".")[1]   + "00" | .[0:2]) )         , "end_time": ( (((.end|tostring) + ".")|split(".")[0] + ".") + ( ((.end|tostring) + ".")|split(".")[1]   + "00" | .[0:2]) ) , "word_group" : ( (((.start|tonumber) + ((.end - .start)|tonumber))/ 5 + 1)|tostring|split(".")[0]|tonumber ) , "word" : (.word|ltrimstr(" "))  }] as $word_json 
|  $word_json[0].start_time as $startoff 
| [$word_json[].word_group]|unique as $wgns 
| [ $wgns[] as $groupnum  
| [ $word_json[] |   select(.word_group==$groupnum ) ]   
# build phrases of words group segments
| {start_time:.[0].start_time,end_time:.[-1].end_time , text:[.[].word]|join(" ")}   ] as $segments 
| [ foreach $segments[] as $item ( 0 ; . + 1 ; $item + {"speaker_id":.} )] 
| {"id":$file_id,"language":$fixitplus_language,"parts": . } 
| [.parts[]|select((.end_time|tonumber) > (.start_time|tonumber))] as $goodparts  
|  .parts|=$goodparts