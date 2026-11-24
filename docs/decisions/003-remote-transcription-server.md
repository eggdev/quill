# ADR-003 :: Remote transcription server

Last updated: `2026.10.29`

> Add a `server/` root: NVIDIA Nemotron 3.5 Transcribe on a GPU host on the
> user's own network. It transcribes each track and labels who spoke. The Mac
> sends it the audio and falls back to its local engine when the host can't
> be reached.

## 1. Decision

- The model is [Nemotron 3.5 Transcribe 30B-A4B](https://huggingface.co/nvidia/NVIDIA-Nemotron-3.5-Transcribe-30B-A4B)
  in FP8, served by vLLM 0.32 with the NeMo Speech plugin. One model gives the
  words, their timestamps, and a speaker tag for each word.
- `server/` is a small adapter in front of vLLM. It joins a track's segment
  files into one recording, asks for a speaker-tagged transcript with word
  timestamps, and splits the words back into the files they came from.
- Both run on a DGX Spark under user systemd units. The adapter is published
  on the tailnet through `tailscale serve` HTTPS.
- The Mac `remote` engine (`transcription.engine`, `transcription.url`) sends
  each track in one request. A voice keeps its number for the whole track,
  across interruptions. Labels are `speaker N` on the iPhone `room` track and
  `them N` on a call's system track. The `me` track is not diarized.
- If the server can't be reached or fails, the coordinator transcribes the
  session with local Parakeet and logs why. The transcript records the engine
  that made it.

## 2. Rationale

The iPhone's one microphone hears everyone in the room, so its transcripts
need speaker labels to be useful. The model attributes speakers as it
transcribes, so words and speakers can't disagree at turn edges. It leads the
published multi-speaker results on full meeting recordings (mean cpWER 15.8
on AMI, CALLHOME, Mixer 6, NOTSOFAR-1) and the open-weight English and
long-form ASR results.

FP8 is near BF16 accuracy at half the memory (35 GB). That fits beside the
other services on the Spark's shared 121 GB.

The recording still goes only to machines the user owns. "Local-only" in the
shared contract means the user's own network.

## 3. Limits

- The model is trained on recordings up to one hour. Longer tracks go in
  55-minute windows, and a voice's number can change between windows.
- The model card's speaker prompt names four tags. More voices than that may
  share a tag.

## 4. When to Revisit

Reconsider if an on-device model gives comparable speaker attribution, or if
recordings longer than an hour become common.
