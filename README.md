Generally, these files are used in the production of JSON-format transcripts for use with the web site americanarchive.org.
Some are configuration files:

• "org.wgbh.mla.s3dockerwhisper.plist" is used by launchd on macOS;

• "s3keyprefix.txt" is used by the subsequent process launched by script "whispermedia.sh"

Scripts with filename extension "jq" may be used more generally to process and reformat JSON typically output from whisper-ai Audio Speech Recognition (ASR).  Use each of the following scripts with `jq ` as a filepath value appended to its switch ` -f `

• "whisper_stammer_less.jq" assumes whisper-format JSON input and outputs a filtered array of objects (with keys: "word", "start", "end") for the purpose of  removing some repetitive "stammering" sequences (presumed to be hallucinatory nonsense)

• "wordarray_2fixitplusJSON.jq" requires use of two `--arg ` switches to transform an array of objects (input requires keys: "word", "start", "end") to output phrase-level JSON

Usage examples:

```
# file arg to jq
jq -f whisper_stammer_less.jq "$whisperfile" | jq --arg fixitplus_language 'en-US' --arg file_id "$(basename $whisperfile | sed 's#[_\.].*##1')" -f wordarray_2fixitplusJSON.jq
```


```
# STDIN to jq
cat $whisperfile | jq -f whisper_stammer_less.jq | jq --arg fixitplus_language 'en-US' --arg file_id "$(basename $whisperfile | sed 's#[_\.].*##1')" -f wordarray_2fixitplusJSON.jq
```

```
# transform whisper JSON without stammer reduction
jq -r '[.segments[].words] |[flatten[]|select((.start|tonumber) < (.end|tonumber))|pick(.word,.start,.end)]' $whisperfile | jq --arg fixitplus_language 'en-US' --arg file_id "$(basename $whisperfile | sed 's#[_\.].*##1')" -f wordarray_2fixitplusJSON.jq
```
