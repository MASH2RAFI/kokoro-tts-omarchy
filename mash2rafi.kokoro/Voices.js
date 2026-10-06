.pragma library

// Kokoro-82M v1.0 voices for the languages whose G2P ships with the base
// install (English via misaki, the rest via espeak-ng). Japanese (j*) and
// Mandarin (z*) voices need misaki[ja] / misaki[zh] and are left out.
var languages = {
  a: "English (US)",
  b: "English (UK)",
  e: "Spanish",
  f: "French",
  h: "Hindi",
  i: "Italian",
  p: "Portuguese (BR)"
}

var voiceIds = [
  "af_heart", "af_alloy", "af_aoede", "af_bella", "af_jessica", "af_kore",
  "af_nicole", "af_nova", "af_river", "af_sarah", "af_sky",
  "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam", "am_michael",
  "am_onyx", "am_puck", "am_santa",
  "bf_alice", "bf_emma", "bf_isabella", "bf_lily",
  "bm_daniel", "bm_fable", "bm_george", "bm_lewis",
  "ef_dora", "em_alex", "em_santa",
  "ff_siwis",
  "hf_alpha", "hf_beta", "hm_omega", "hm_psi",
  "if_sara", "im_nicola",
  "pf_dora", "pm_alex", "pm_santa"
]

function label(id) {
  var lang = languages[id.charAt(0)] || "?"
  var gender = id.charAt(1) === "f" ? "♀" : "♂"
  var name = id.slice(3)
  name = name.charAt(0).toUpperCase() + name.slice(1)
  return name + "  " + gender + "  · " + lang
}

function options() {
  var out = []
  for (var i = 0; i < voiceIds.length; i++)
    out.push({ value: voiceIds[i], label: label(voiceIds[i]) })
  return out
}

function isKnown(id) {
  return voiceIds.indexOf(String(id || "")) >= 0
}
