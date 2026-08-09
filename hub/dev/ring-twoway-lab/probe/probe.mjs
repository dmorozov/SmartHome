// Ring live-call protocol probe — experiment B1/B2 in ../README.md
//
// Answers three questions and nothing else:
//   1. Does a live call to this doorbell answer at all?
//   2. Which codec does Ring pick — Opus 48k stereo, or PCMU 8k mono?
//   3. (with --play) does sound actually come out of the doorbell's speaker?
//
// Question 2 is the load-bearing one: the answer changes the encoder, the
// channel count and the sample rate for everything downstream, and it is
// decided by Ring at answer time, not by us. The library detects it by
// string-sniffing the SDP answer for ' opus/'.
//
// Run from a HOST terminal, in /home/dmorozov/Work/SmartHome/hub/dev/ring-twoway-lab
// (NOT /workspaces/... — that path exists on the host too, and is the wrong tree;
// see ../README.md §2.1). The token lives outside the repo per ADR-0010:
//
//   docker run --rm -it --network host -v "$PWD/probe:/probe" \
//     --env-file ~/.sh_keys/ring-twoway-lab.env \
//     node:22-alpine sh -c 'apk add --no-cache ffmpeg >/dev/null \
//       && cd /probe && npm i --silent && node probe.mjs'
//
// Add --play /probe/test.wav to also push audio to the speaker (experiment B2).

import { RingApi } from '@tsightler/ring-client-api'

// camera.id / doorbot_id — the ONLY identifier the streaming path sends.
// NOT the MAC-like device_id 90486cf35236, which ring-client-api never sends
// anywhere. See ../README.md §1.5 for why these are easy to confuse.
const CAMERA_ID = Number(process.env.RING_CAMERA_ID || 319156885)

// startLiveCall() has no library-level timeout. A doorbell that never answers
// hangs the promise forever — the same unbounded-wait flaw go2rtc's
// connected.Wait() has. Ours must be bounded or we learn nothing.
const ANSWER_TIMEOUT_MS = Number(process.env.RING_ANSWER_TIMEOUT_MS || 30_000)

const playPathIdx = process.argv.indexOf('--play')
const playPath = playPathIdx > -1 ? process.argv[playPathIdx + 1] : null
const holdMs = Number(process.env.RING_HOLD_MS || (playPath ? 15_000 : 8_000))

const t0 = Date.now()
const el = () => `${((Date.now() - t0) / 1000).toFixed(1)}s`
const ok = (m) => console.log(`\x1b[32m✓\x1b[0m [${el()}] ${m}`)
const info = (m) => console.log(`\x1b[36m→\x1b[0m [${el()}] ${m}`)
const bad = (m) => console.log(`\x1b[31m✗\x1b[0m [${el()}] ${m}`)

if (!process.env.RING_REFRESH_TOKEN) {
  bad('RING_REFRESH_TOKEN is not set — see ../README.md §2')
  process.exit(2)
}

// The base64-JSON envelope check from experiment A3, applied here too: a token
// that does not start `eyJy` is not {"rt":...,"hid":...} and carries no
// hardware id. The library tolerates it; go2rtc silently blanks hardware_id.
if (!process.env.RING_REFRESH_TOKEN.startsWith('eyJy')) {
  console.log(
    `\x1b[33m!\x1b[0m token does not start with "eyJy" — it may be a raw token ` +
      `rather than the base64-JSON envelope. Not fatal here, but see §1.5.`,
  )
}

const ringApi = new RingApi({
  refreshToken: process.env.RING_REFRESH_TOKEN,
  debug: true, // turns on the library's own debug('ring') logging
  // getFfmpegPath() returns undefined unless this is set, and the encoder is
  // chosen at runtime as libopus OR pcm_mulaw depending on Ring's answer — so
  // the binary must have both. `spawn ffmpeg ENOENT` is a recurring reported
  // failure upstream (dgreif/ring #1788, #1752).
  ffmpegPath: process.env.FFMPEG_PATH || 'ffmpeg',
})

// Refresh tokens are single-use and rotate. If this fires, the token in .env is
// already stale — persist the new one or the next run fails.
ringApi.onRefreshTokenUpdated.subscribe(({ newRefreshToken }) => {
  if (!newRefreshToken) return
  console.log(
    `\x1b[33m!\x1b[0m refresh token ROTATED. Update .env with the new value ` +
      `(first 12 chars: ${newRefreshToken.slice(0, 12)}…) or the next run will fail.`,
  )
})

let call = null
const shutdown = async (code) => {
  try {
    if (call) {
      info('stopping call…')
      call.stop()
    }
  } catch (e) {
    bad(`stop threw: ${e?.message ?? e}`)
  }
  // Give the {method:'close'} message a moment to leave the socket.
  setTimeout(() => process.exit(code), 750)
}
process.on('SIGINT', () => shutdown(130))

try {
  info('authenticating…')
  const cameras = await ringApi.getCameras()
  ok(`authenticated — ${cameras.length} camera(s) on the account`)

  for (const c of cameras) {
    console.log(
      `    id=${c.id}  device_id=${c.data.device_id ?? '?'}  ` +
        `battery=${c.hasBattery}  "${c.name}"`,
    )
  }

  const camera = cameras.find((c) => c.id === CAMERA_ID)
  if (!camera) {
    bad(`camera ${CAMERA_ID} not found — pick an id from the list above`)
    process.exit(1)
  }
  ok(`found camera ${camera.id} "${camera.name}" (battery: ${camera.hasBattery})`)

  // Added in 14.3.0: startLiveCall throws if Ring app Modes disabled live view.
  // Worth surfacing explicitly — it is an easy, invisible way to be blocked.
  if (camera.data?.settings?.live_view_disabled) {
    bad('live_view_disabled is TRUE for this camera — check Modes in the Ring app')
  }

  info('startLiveCall() — this is the wake trigger; no push subscription needed')
  const guard = setTimeout(() => {
    bad(`NO ANSWER within ${ANSWER_TIMEOUT_MS / 1000}s.`)
    bad('Ring accepted the request and never answered — the same shape go2rtc hits.')
    bad('This means the problem is NOT go2rtc-specific. See ../README.md §6.')
    shutdown(1)
  }, ANSWER_TIMEOUT_MS)

  call = await camera.startLiveCall()
  ok('startLiveCall() returned — signalling socket is open')

  call.onCallEnded.subscribe(() => {
    clearTimeout(guard)
    info('call ended')
  })

  // THE ANSWER. This promise resolves only when Ring sends the SDP answer, so
  // awaiting it is also the definitive "did the doorbell pick up?" test.
  const usingOpus = await call.isUsingOpus
  clearTimeout(guard)
  ok(`ANSWERED. usingOpus = ${usingOpus}`)
  ok(
    usingOpus
      ? 'Ring chose OPUS 48000 Hz stereo → encode with: -acodec libopus -ac 2 -ar 48k'
      : 'Ring chose PCMU 8000 Hz mono   → encode with: -acodec pcm_mulaw -ac 1 -ar 8k',
  )

  if (playPath) {
    info('activateCameraSpeaker() — required, one-shot, latches for the call')
    // Without this the doorbell stays in stealth_mode and outbound audio is
    // silently discarded AT THE DEVICE. It queues on camera_connected and fires
    // exactly once; it cannot be re-armed without restarting the call.
    call.activateCameraSpeaker()

    info(`transcodeReturnAudio({ input: ['${playPath}'] })`)
    // TRAP: `input` is spliced AFTER `-i` here, but BEFORE `-i` in
    // startTranscoding(). Same field name, opposite semantics. So this must be
    // a bare file path or URL — one element, no flags. A live mic cannot go
    // through this helper; see ../README.md §B3.
    await call.transcodeReturnAudio({ input: [playPath] })
    ok('return audio started — GO STAND AT THE DOOR')
  }

  info(`holding the call open for ${holdMs / 1000}s…`)
  setTimeout(() => shutdown(0), holdMs)
} catch (err) {
  bad(`${err?.message ?? err}`)
  if (String(err).includes('406')) {
    bad('406 → Cloudflare WAF. See ../README.md §1.1 — this is the User-Agent block.')
  }
  if (String(err).match(/401|invalid_grant/)) {
    bad('401/invalid_grant → the refresh token is stale. Re-mint with ring-auth-cli.')
  }
  await shutdown(1)
}
