/// What a URL is allowed to say in a log line, in one place.
///
/// Two entry points over one idea. [urlForLog] and [addressForLog] take a URL
/// the Panel was *configured* with and build a log field up out of its
/// scheme, host and port; [redactCredentials] takes a sentence some other
/// process composed, finds the URLs inside it, and cuts each one down with the
/// same builder. Both are the answer to the same question and they live
/// together because they were written twice and drifted: `main.dart` grew
/// `go2rtcForLog` for `GO2RTC_URL` and taught it — over two rounds — that
/// userinfo is not the only part of a URL that can carry a password, while
/// `HA_URL`, one field over in the same `HubConfig`, was still printed whole
/// on every healthy boot. A second copy is how that happens.
///
/// See `diagnostics/log.dart`: **Never log a secret.**
library;

/// The scheme, host and port of [url] and nothing else —
/// `http://10.0.0.5:1984` — or `unusable` when there is no host to build one
/// from.
///
/// Built up from named parts rather than stripped down from the value. That
/// direction is the whole design and it was arrived at by losing the argument
/// twice: a strip-based rule dropped `Uri.userInfo` and kept the rest on the
/// stated ground that userInfo "is the only part of a URL that can carry a
/// credential" — true of go2rtc 1.9's basic auth, false of URLs — and
/// `?password=…` went through verbatim; the path was then kept on the same
/// "cannot carry a credential" reasoning and measured carrying one
/// (`http://10.0.0.5:1984/hunter2/`). Building up is the only shape where the
/// next part somebody adds to a URL is excluded by default rather than
/// published by default.
///
/// `unusable` rather than an echo, and both halves matter. `Uri.tryParse`
/// hardly ever fails: it takes `admin:hunter2@hub:1984` apart as scheme
/// `admin` with the rest as a path — nothing that looks like a credential to
/// any accessor — so "it parsed" is evidence of nothing. If we cannot see a
/// URL's parts we cannot say what is in it, and an honest unknown beats a
/// confident wrong answer.
String addressForLog(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return 'unusable';
  return Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
  ).toString();
}

/// [addressForLog] plus a word for each part that was dropped, so a line can
/// say *that* a Panel was given a credential without saying what it was.
///
/// `path=set` / `query=set` / `fragment=set` / `auth=set`, in log.dart's own
/// `token=set` vocabulary. Reporting presence is not decoration: an operator
/// who put `api.username` into `GO2RTC_URL`, or a reverse-proxy mount point
/// into `HA_URL`, needs to see that the Panel received it, and silently
/// printing a shortened URL reads as "nothing was configured". Reporting
/// *every* dropped part, rather than the two somebody thought of, is what
/// keeps this docstring true when a URL grows a part nobody here has heard of.
///
/// `/` is not a mount point anybody chose — `http://host:1984` and
/// `http://host:1984/` are the same address — so it earns no `path=set`, or
/// the word would appear on every ordinary Panel and mean nothing.
///
/// Public and probed rather than reasoned about: the one way to know a log
/// line carries no credential is to hand it one and read what comes out, and
/// this rule has been wrong twice. `test/url_redaction_test.dart` is the
/// interrogation.
Map<String, Object?> urlForLog(String url) {
  if (url.isEmpty) return {'url': 'absent'};
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return {'url': 'unusable'};
  return {
    'url': addressForLog(url),
    if (uri.path.isNotEmpty && uri.path != '/') 'path': 'set',
    if (uri.hasQuery) 'query': 'set',
    if (uri.hasFragment) 'fragment': 'set',
    if (uri.userInfo.isNotEmpty) 'auth': 'set',
  };
}

/// Somebody else's words, with every URL in them cut down to an address and
/// the credential shapes below struck out of what is left.
///
/// Written for go2rtc's error frames, which quote the producer they failed to
/// dial — and a producer in `go2rtc.yaml` is routinely
/// `rtsp://user:pass@camera`, so `{"type":"error","value":"streams: dial
/// rtsp://admin:hunter2@cam:554/h264: connection refused"}` puts a camera
/// password into journald by way of `LiveVideoSession.failure`. Now also used
/// on `ha_hub.dart`'s socket errors, where `dart:io`'s `HttpException` appends
/// `uri = …` to its own message and published `HA_URL` whole.
///
/// **Two structural rules, then a short list of shapes for what structure
/// cannot reach — and the list is best-effort.** This docstring has three
/// times claimed more than it delivered: that the fix "is applied to the text
/// unconditionally rather than to the cases somebody thought of" (a regex *is*
/// the cases somebody thought of); that five named shapes covered it, when
/// Foscam's real `?loginuse=…&loginpas=…` contains neither `user` nor `pass`
/// and went to `popup.stream_failed` verbatim; and that quoting was structure
/// enough, when go2rtc answers an `ffmpeg:` producer with **ffmpeg's own
/// stderr**, where the URL is bare:
///
///     Error opening input file http://127.0.0.1:9/cgi-bin/CGIProxy.fcgi
///     ?loginuse=admin&loginpas=hunter2.
///
/// That third one hid well, and the two-producer camera layout this project
/// adopted (`hub/go2rtc/go2rtc.example.yaml`) makes an `ffmpeg:` line
/// mandatory on every camera, so it is the reachable case rather than the
/// exotic one. It hid because ffmpeg masks *userinfo* itself
/// (`http://***@host/live`), so every userinfo probe came back clean and the
/// channel looked guarded.
///
/// The structure, in both cases, is that **a URL has a recognisable start**:
/// `scheme://`. Inside double quotes it also has a recognisable end, because
/// Go's `%q` put it there — `url.Error` renders the URL in quotes and the
/// reason after them, so the sentence splits cleanly into a part composed from
/// the operator's configuration and a part composed by Go. In prose the end is
/// whitespace, a quote, or the sentence punctuation the URL was followed by.
/// Either way the run is handed to [addressForLog] and reduced to scheme,
/// host and port, with no opinion here about which part of the rest was the
/// credential.
///
/// **The path in an unquoted URL now goes too.** The previous round accepted
/// it as a residual — `http://cam/api/<token>/live` was left alone, because
/// "outside quotes there is no boundary that says where the URL stopped". The
/// boundary is the same one that finds the query, so keeping the path would
/// have been "this part looks safe" one more time. Decision changed; that
/// residual is closed.
///
/// What it costs, stated because it is a real loss: go2rtc's `#key=value`
/// source options (`#video=h264`, `#backchannel=0`) no longer survive when
/// they hang off a `scheme://` URL — `rtsp://cam/live#media=video` logs as
/// `rtsp://cam <redacted>`. They do survive on the producer names go2rtc
/// writes without an authority, such as `ffmpeg:selftest#video=mjpeg`, which
/// is the form the Panel's own streams take. The quoted `?src=<stream>` is
/// likewise gone and is not lost: the Stream Director logs the stream as its
/// own field on the same line (`cameras.popup_failed name=cam_porch reason=…`).
/// Host and port survive, which is the half that says *which* daemon or
/// camera, and the unquoted remainder — `mse: stream not found`, `connection
/// refused`, `dial tcp …` — is untouched.
///
/// **Where the rules stop.** Say it plainly, because five rounds of this
/// feature have shipped a comment asserting a safety property that measurement
/// disproved:
///
/// - A URL with **whitespace inside it** ends the structural run early. A
///   password may legally contain a space, so shapes 1–3 below still carry
///   that case, and they redact towards eating too much of the sentence.
/// - A **schemeless** `user:pass@host:554` — which go2rtc writes when the
///   producer was configured without a scheme — has no `://` to anchor on;
///   shape 3 is the only thing that sees it.
/// - Trailing `.,;:!?` are treated as the sentence's punctuation and left
///   outside the redacted span, because ffmpeg ends its line with `.` and Go
///   separates URL from reason with `:`. So a credential whose own last
///   character is one of those leaves that one character behind
///   (`?p=hunter2.` → `<redacted>.`). One character, stated rather than
///   pretended away.
/// - A run that starts `scheme://` and does **not** parse (`http://h:notaport`)
///   loses its address as well: there is nothing to build up from, so the
///   whole run becomes `<redacted>`. Safe, and less useful.
/// - Anything that is not a URL and not one of the shapes below is untouched,
///   which is the point — the reason an operator came for has to survive.
///
/// Where this is wrong it is wrong towards redacting too much (an `@` later in
/// a sentence can pull a clause into shape 2 or 3), which is the direction to
/// be wrong in, and why the reason is logged and never branched on: nothing
/// downstream behaves differently because of what the sentence says.
///
/// The shapes, each measured against the live daemon:
///
/// 1. `scheme://user:pass@` — the one this started as. Widened, because a
///    password may legally contain `/` and did pass through whole.
/// 2. the same with whitespace inside the password, capped so it cannot run
///    away down the sentence.
/// 3. schemeless `user:pass@host:554`.
/// 4. a query parameter whose *name* says it carries a credential. This was
///    once the centre of the rule and is the guess that was measured wrong; it
///    is kept only for text with no parseable `scheme://` run in it, and
///    nothing here relies on it.
/// 5. an `Authorization: Basic <base64>` line, where the base64 is the
///    credential.
///
/// Deleted along the way: a rule that struck out a URL fragment which was not
/// one of go2rtc's `#key=value` options. It was anchored to `scheme://`, so
/// the structural rules now reach every string it could reach, and it was the
/// last guess in this file about what a URL *means*.
///
/// Rejected: dropping the value entirely. `mse: stream not found` is what an
/// operator needs, and "go2rtc said no" with no reason is exactly the grey
/// rectangle this feature exists to stop showing, one layer down.
String redactCredentials(String text) => text
    // Quoted first: inside quotes the structural rule subsumes the shape
    // rules, so running it first stops them rewriting a URL this is about to
    // replace wholesale and leaving `<redacted>` fragments stranded inside the
    // quotes.
    .replaceAllMapped(_quotedUrl, (m) => '"${_addressOnly(m.group(1)!)}"')
    .replaceAllMapped(_credentialQuery, (m) => '${m.group(1)}<redacted>')
    .replaceAllMapped(
        _userInfo, (m) => '${m.group(1) ?? m.group(2) ?? ''}<redacted>@')
    .replaceAllMapped(_authorization, (m) => '${m.group(1)} <redacted>')
    // Unquoted last, the opposite order from the quoted rule and for the
    // opposite reason: a shape rule's `<redacted>` survives a re-parse
    // (`Uri` percent-encodes it into the userinfo or query it replaced) and is
    // then swallowed by the address, whereas running this first would cut the
    // run short at the space inside a password and leave the tail of it in the
    // sentence with no `@` left for shape 2 to find.
    .replaceAllMapped(_bareUrl, (m) => _addressOnly(m.group(0)!));

/// A double-quoted run that looks like a URL: a scheme, `://`, and no
/// whitespace or quote until the closing one.
///
/// The whitespace bound is what stops this matching a quoted *sentence* that
/// happens to mention a URL, and the quote bound is what stops one match
/// spanning two quoted strings. Both are properties of URLs rather than of
/// go2rtc, which is the point — this fires on `Get "…"`, on `dial "…"`, and on
/// whatever Go wraps the next error in.
final _quotedUrl = RegExp(r'"([a-zA-Z][a-zA-Z0-9+.\-]*://[^"\s]*)"');

/// The same run without the quotes: from `scheme://` to whitespace, a quote,
/// or the sentence punctuation that ended it.
///
/// The final-character class is the whole difference from [_quotedUrl] and it
/// is doing two jobs. ffmpeg writes `Error opening input file <url>.` and Go
/// writes `<url>: connection refused`, so a match that ran to the whitespace
/// would pull the sentence's own punctuation inside the redacted span and read
/// as if the process had stopped mid-word. And because the address is rebuilt
/// from `Uri.host` afterwards, a trailing `.` that really was part of a
/// fully-qualified host is not lost either — it stays in the text, one
/// character to the right of where it started.
///
/// Idempotent over this file's own output: `"http://host:1984 <redacted>"`
/// re-matches as `http://host:1984`, which has nothing left to take out.
final _bareUrl = RegExp(r'[a-zA-Z][a-zA-Z0-9+.\-]*://[^\s"]*[^\s".,;:!?]');

/// The address out of [url] and nothing else.
///
/// The trailing marker is added only when something was actually taken out, so
/// a bare `http://host:1984` is not made to look like it had a secret in it.
String _addressOnly(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null || uri.host.isEmpty) return '<redacted>';
  final more = uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment ||
      (uri.path.isNotEmpty && uri.path != '/');
  return more ? '${addressForLog(url)} <redacted>' : addressForLog(url);
}

/// A query parameter whose *name* says it carries a credential, from `?` or
/// `&` or `;` up to the next separator.
///
/// Matched on the name rather than the value because a value is just text.
/// Shape 4 above: a leftover for text with no parseable URL in it, kept
/// because it is free and nothing depends on it. The value stops at `"` as
/// well as at `&` and whitespace, so a parameter this matches inside a quoted
/// URL that [_quotedUrl] declined still loses its value rather than its
/// neighbours.
final _credentialQuery = RegExp(
    r'([?&;][^=&\s]*(?:pass|pwd|user|token|auth|key|secret|cred|sig)[^=&\s]*=)'
    r'[^&\s"]*',
    caseSensitive: false);

/// A URL's userinfo in the three shapes go2rtc has been seen to write.
///
/// Three alternatives rather than one permissive pattern, because the bound
/// is what stops a redaction eating a whole sentence: the first refuses
/// whitespace, the second buys whitespace by demanding a `user:` in front and
/// capping the password at 64 characters and at the `"` that ends a quoted
/// URL, and the third refuses `/` and whitespace so that a bare
/// `nobody@example.com` — which has no `:` before the `@` — is left alone.
final _userInfo = RegExp(
    r'([a-zA-Z][a-zA-Z0-9+.\-]*://)[^\s@]*@'
    r'|([a-zA-Z][a-zA-Z0-9+.\-]*://)[^\s@:]*:[^@"\n]{0,64}@'
    r'|(?<![\w.\-])[\w.\-]+:[^\s@/]*@');

/// `Basic <base64>` and its neighbours, wherever a header line was quoted
/// back. The scheme word is kept: "the credential we sent was a Bearer token"
/// is diagnostic, the token is not.
final _authorization =
    RegExp(r'\b(Basic|Bearer|Digest|Negotiate)\s+[A-Za-z0-9+/=._\-]+');
