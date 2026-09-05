/// Where go2rtc is, once the raw setting has been read for what it is.
///
/// `GO2RTC_URL` arrives as a plain string and has three meanings, not two:
/// nobody named a go2rtc, somebody named something that is not an address, or
/// here it is. Those three used to be re-derived from the string at four call
/// sites — `VideoConfig.urlFor`, `Go2rtcStillsConfig.urlFor`,
/// `TalkConfig._urlFor` and the Stream Director's skip reason — and three of
/// the four said in a comment that they were copying the first.
///
/// **"Parsed once" means the rule is written once, not that parsing runs
/// once.** `VideoConfig`, `TalkConfig` and `Go2rtcStillsConfig` all have
/// `const` constructors, and ten-odd default parameter values across `lib/`
/// and `test/` depend on that (`this.talk = const TalkConfig()`), so none of
/// them can hold a `late final` parsed field. Each derives its address from a
/// getter, which parses on the call exactly as the four copies did. Nothing
/// got faster; what changed is that there is one place to be right, and a
/// caller can no longer silently forget a case — [Go2rtcAddress] is sealed,
/// so a `switch` that misses one does not compile.
///
/// Deliberately not the Hub's half. `SnapshotConfig.urlFor` guards `HA_URL`
/// with the same shape and keeps its own copy, because the two are not the
/// same decision: a bad `HA_URL` stops the Hub and `HaHubClient` throws inside
/// `bootPanel` to say so across the room, while a bad `GO2RTC_URL` must only
/// ever cost the picture. Merging them would make one rule out of two
/// deliberately different answers.
///
/// Deliberately not the transport mappers either: `live_video_mjpeg.dart` and
/// `live_video_rtsp_io.dart` turn the seam's URL into their own form, and both
/// record why that lives inside the transport file.
sealed class Go2rtcAddress {
  const Go2rtcAddress();

  /// Reads [raw] — the value `GO2RTC_URL` resolved to — for which of the
  /// three it is.
  ///
  /// Empty is [Go2rtcAbsent] rather than [Go2rtcUnusable], and the difference
  /// is not pedantry: the Panel has no built-in go2rtc address on purpose
  /// (`hub_config.dart`), so "nobody has told me where go2rtc is" is a
  /// supported boot state and a different fix from "what you told me is not
  /// an address".
  factory Go2rtcAddress.parse(String raw) {
    if (raw.isEmpty) return const Go2rtcAbsent();
    final base = Uri.tryParse(raw);
    // `Uri.tryParse` is generous: `localhost:1984` parses happily, as a URI
    // with scheme `localhost` and no host at all. Requiring a host is what
    // separates an address from a typo, and it is the whole of what the four
    // copied guards were checking.
    if (base == null || base.host.isEmpty) return const Go2rtcUnusable();
    return Go2rtcAt(base);
  }
}

/// Nobody named a go2rtc. A supported state, not a fault: the Panel refuses to
/// invent an address, so every camera simply has no live face and the boot
/// line says `GO2RTC_URL=absent`.
final class Go2rtcAbsent extends Go2rtcAddress {
  const Go2rtcAbsent();
}

/// Somebody named something that is not an address. A fault, and one that must
/// cost only the picture — never the Dialog it is drawn in.
final class Go2rtcUnusable extends Go2rtcAddress {
  const Go2rtcUnusable();
}

/// Here it is.
final class Go2rtcAt extends Go2rtcAddress {
  const Go2rtcAt(this.base);

  /// The parsed base, e.g. `http://192.168.68.81:1984`. Every caller reshapes
  /// this into its own endpoint — `/api/ws`, `/api/frame.jpeg`,
  /// `/api/streams` — and the reshaping stays theirs: what is shared is
  /// reading the address, not spelling the endpoint.
  final Uri base;
}
