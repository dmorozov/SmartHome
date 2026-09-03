import 'package:flutter_test/flutter_test.dart';
import 'package:panel/diagnostics/log.dart';
import 'package:panel/diagnostics/url_redaction.dart';

/// The interrogation. Every case here is a real shape somebody can paste into
/// a systemd unit or a `go2rtc.yaml`, or a real sentence a daemon was measured
/// answering with.
///
/// The one way to know a log line carries no credential is to hand it one and
/// read what comes out. This rule has now been wrong four times — userinfo was
/// "the only part of a URL that can carry a credential"; the path "could not
/// carry one"; five named query-parameter names "covered it"; and Go's quoting
/// was "structure enough". Each was a comment asserting a safety property that
/// measurement disproved, so the assertions below are written against the
/// rendered line rather than against the function's return value wherever a
/// caller exists to drive.
///
/// Was `test/go2rtc_log_test.dart`, and grew when `HA_URL` turned out to be
/// the same setting with none of the same protection.
void main() {
  const password = 'hunter2';

  group('the fields a configured URL becomes', () {
    /// Everything the field rendering could publish, flattened.
    String logged(String url) =>
        urlForLog(url).entries.map((e) => '${e.key}=${e.value}').join(' ');

    test('the address survives so the log can say which server, and the '
        'credential in it does not', () {
      expect(logged('http://admin:$password@10.0.0.5:1984'),
          'url=http://10.0.0.5:1984 auth=set');
      expect(logged('https://admin:$password@hub.example/go2rtc/'),
          'url=https://hub.example path=set auth=set');
    });

    test('a credential in the path is not published either, which is the last '
        'part of a URL this line was still printing whole', () {
      // Measured: `url=http://10.0.0.5:1984/hunter2/` reached `popup.go2rtc`,
      // against `appliance/ansible/README.md`'s flat "A credential in this
      // setting never reaches the journal." A path is a reverse-proxy mount
      // point, so its presence is worth a word and its text is not — host and
      // port are the whole answer to "which server".
      for (final url in [
        'http://10.0.0.5:1984/$password/',
        'http://10.0.0.5:1984/;pass=$password',
        'http://10.0.0.5:1984/go2rtc/$password',
      ]) {
        expect(logged(url), isNot(contains(password)), reason: url);
        expect(logged(url), 'url=http://10.0.0.5:1984 path=set', reason: url);
      }
    });

    test('a server at the root says nothing about a path, so path=set means '
        'somebody really did mount it somewhere', () {
      // `http://host:1984` and `http://host:1984/` are the same address, and
      // reporting the second as mounted would put `path=set` on every ordinary
      // Panel and make the word mean nothing.
      expect(logged('http://10.0.0.5:1984'), 'url=http://10.0.0.5:1984');
      expect(logged('http://10.0.0.5:1984/'), 'url=http://10.0.0.5:1984');
    });

    test('a query or a fragment is dropped whole, because userinfo was never '
        'the only place a URL can keep a password', () {
      // The regression: the rule dropped `Uri.userInfo` and kept everything
      // else, justified by the claim that userInfo is the only part of a URL
      // that can carry a credential. `?password=…` went through verbatim.
      for (final url in [
        'http://10.0.0.5:1984/?password=$password',
        'http://10.0.0.5:1984/#$password',
        'http://10.0.0.5:1984/?token=$password#$password',
      ]) {
        expect(logged(url), isNot(contains(password)), reason: url);
        expect(logged(url), contains('10.0.0.5:1984'), reason: url);
      }
    });

    test('every dropped part still reports that it was there, so a shortened '
        'address cannot read as "nothing was configured"', () {
      // The failure mode this prevents is quiet: an operator who put
      // `?api_password=` into HA_URL, or `api.username` into GO2RTC_URL, needs
      // to see that the Panel received it. Reporting *every* dropped part
      // rather than the two somebody thought of is also what keeps the
      // docstring true the next time a URL grows a part.
      expect(logged('http://ha.local:8123/?api_password=$password'),
          'url=http://ha.local:8123 query=set');
      expect(logged('http://ha.local:8123/#$password'),
          'url=http://ha.local:8123 fragment=set');
      expect(logged('https://admin:$password@ha.local/house/?t=$password#f'),
          'url=https://ha.local path=set query=set fragment=set auth=set');
    });

    test('a value with no host is not echoed at all — a URL nobody can take '
        'apart is a URL nobody can vouch for', () {
      // The regression this pins: `Uri.tryParse` hardly ever fails, and a
      // schemeless paste is taken apart as scheme `admin` with the rest as a
      // path — `userInfo` empty, `host` empty, nothing that looks like a
      // credential to any accessor, so a strip-based rule printed the lot.
      expect(logged('admin:$password@hub:1984'), 'url=unusable');
      // And the same for the shapes that always reported unusable, which must
      // keep doing so: `urlFor` refuses both, so there is no picture either.
      expect(logged('10.0.0.5:1984'), 'url=unusable');
      expect(logged('http://admin:$password@10.0.0.5:notaport'), 'url=unusable');
    });

    test('an unset address says absent rather than pretending to one', () {
      // `absent` is `ConfigSource`'s own word for "nobody named one", and the
      // hermetic default: a Panel with no go2rtc still shows every Device.
      expect(logged(''), 'url=absent');
    });

    test('an address with no credential in it reports none, so auth=set means '
        'the Panel really was given one', () {
      expect(logged('http://10.0.0.5:1984'), 'url=http://10.0.0.5:1984');
      expect(logged('https://hub.example/go2rtc/'),
          'url=https://hub.example path=set');
    });

    test('the bare-address form keeps the one fact a connect line needs and '
        'says unusable rather than echoing anything else', () {
      // What `hub.connecting` and `hub.connected` print. They take the address
      // alone because their Uri's path is `/api/websocket`, which the Panel
      // appended itself — `path=set` there would be on every Hub forever.
      expect(addressForLog('ws://admin:$password@ha.local:8123/api/websocket'),
          'ws://ha.local:8123');
      expect(addressForLog('ws:/api/websocket'), 'unusable');
    });
  });

  group('a sentence another process composed', () {
    test('go2rtc\'s own words keep a camera password out of journald', () {
      // The MSE player logs go2rtc's error frame verbatim, and go2rtc quotes
      // the producer it failed to dial — which in `go2rtc.yaml` is routinely
      // an rtsp URL with the camera's password in it.
      expect(
          redactCredentials('streams: dial rtsp://admin:$password@cam:554/h264'
              ': connection refused'),
          'streams: dial rtsp://cam:554 <redacted>: connection refused');
    });

    test('an ffmpeg: producer\'s stderr loses its URL too, though nothing in '
        'it is quoted', () {
      // The fourth leak, measured in real Chrome against the live daemon.
      // go2rtc answers an `ffmpeg:`-sourced producer with ffmpeg's own
      // multi-line stderr, where the URL is bare — so the quoted-URL rule,
      // which keys on Go's `%q`, never saw it, and the only guard left was the
      // parameter-name guess that Foscam's `loginuse`/`loginpas` defeats.
      //
      // It is the reachable case rather than the exotic one:
      // `hub/go2rtc/go2rtc.example.yaml` and `appliance/ansible/README.md`
      // make an `ffmpeg:` line mandatory on every camera, and both producers
      // of this deployment's own `selftest` are `ffmpeg:` lines.
      const said = 'go2rtc refused: mse: streams: exec/pipe: EOF\n'
          '[tcp @ 0x7691306c8ec0] Connection to tcp://127.0.0.1:9 failed: '
          'Connection refused\n'
          '[in#0 @ 0x76912c0bd980] Error opening input: Connection refused\n'
          'Error opening input file http://127.0.0.1:9/cgi-bin/CGIProxy.fcgi'
          '?loginuse=admin&loginpas=$password.\n'
          'Error opening input files: Connection refused\n';
      final clean = redactCredentials(said);

      expect(clean, isNot(contains(password)));
      expect(clean, isNot(contains('admin')));
      // And the four lines an operator actually came for are all still here,
      // including the trailing full stop that ffmpeg — not the URL — wrote.
      expect(clean, contains('Error opening input file http://127.0.0.1:9 '
          '<redacted>.\n'));
      expect(clean, contains('Connection to tcp://127.0.0.1:9 failed'));
      expect(clean, contains('exec/pipe: EOF'));
      expect(clean, contains('Error opening input files: Connection refused'));
    });

    test('the same URL leaks nothing whether the daemon quoted it or not, '
        'which is the asymmetry that hid this for a round', () {
      // The control that proved it was the quoting and not the shape: the
      // SAME Foscam URL as a bare (non-ffmpeg) producer comes back quoted by
      // Go, and came back redacted, so every probe through a quoted producer
      // said the channel was guarded.
      const url = 'http://127.0.0.1:9/cgi-bin/CGIProxy.fcgi'
          '?loginuse=admin&loginpas=$password';
      for (final said in [
        'mse: streams: Get "$url": dial tcp 127.0.0.1:9: connect: connection '
            'refused',
        'Error opening input file $url.',
      ]) {
        expect(redactCredentials(said), isNot(contains(password)),
            reason: said);
        expect(redactCredentials(said), contains('http://127.0.0.1:9'),
            reason: said);
      }
    });

    test('ffmpeg masking the userinfo itself does not make the rest of the '
        'URL safe', () {
      // Why every userinfo probe through an `ffmpeg:` source came back clean
      // while the query beside it was published: ffmpeg writes `***` where the
      // userinfo was, all by itself.
      expect(
          redactCredentials(
              'Error opening input file http://***@127.0.0.1:9/live.'),
          'Error opening input file http://127.0.0.1:9 <redacted>.');
    });

    test('a credential in an unquoted URL\'s path goes now too — the decision '
        'the previous round made the other way', () {
      // Stated because it is a changed decision, not a widened claim:
      // `http://cam/api/<token>/live` used to be left alone on the ground that
      // outside quotes there was no boundary saying where the URL stopped.
      // The boundary is the same one that finds the query, so keeping the path
      // would have been "this part looks safe" one more time.
      expect(
          redactCredentials(
              'Error opening input file http://127.0.0.1:9/api/${password}tok'
              '/live.'),
          'Error opening input file http://127.0.0.1:9 <redacted>.');
    });

    test('a password containing a slash or a space is not a password the rule '
        'stops knowing about', () {
      // `[^\s/@]*@` refused both characters, so both went through whole — and
      // a password is exactly the field where an operator is told to use odd
      // characters. A space also ends the structural run early, which is why
      // the userinfo shapes still have to exist.
      for (final said in [
        'streams: dial rtsp://admin:hun/$password@cam/live: refused',
        'streams: dial rtsp://admin:hun $password@cam/live: refused',
      ]) {
        expect(redactCredentials(said), isNot(contains(password)),
            reason: said);
        expect(redactCredentials(said), contains('refused'), reason: said);
      }
    });

    test('a producer configured without a scheme still has its credential '
        'taken out', () {
      // No `://` to anchor the structural rule on, so shape 3 is the only
      // thing that sees this one.
      expect(redactCredentials('streams: dial admin:$password@cam:554: '
          'refused'),
          'streams: dial <redacted>@cam:554: refused');
    });

    test('an Authorization header quoted back keeps its scheme word and loses '
        'the base64 that is the credential', () {
      expect(redactCredentials('streams: Authorization: Basic YWRtaW46$password'),
          'streams: Authorization: Basic <redacted>');
    });

    test('a sentence with no credential in it is passed through unchanged, so '
        'the reason an operator needs is still the reason they get', () {
      for (final said in [
        'mse: unsupported codec',
        'mse: stream not found',
        'streams: stream not found',
        'exec: exit status 1 (ffmpeg)',
        'dial tcp 192.168.68.44:554: connect: connection refused',
        // A URL that is only an address is not made to look like it had a
        // secret taken out of it — quoted or not.
        'mse: Get "http://127.0.0.1:1984": EOF',
        'Connection to tcp://127.0.0.1:9 failed: Connection refused',
      ]) {
        expect(redactCredentials(said), said, reason: said);
      }
    });

    test('a quoted URL loses everything but its address, so a credential in a '
        'parameter nobody has heard of goes with the rest', () {
      // The measured failure of name-matching, in real Chrome against the
      // live daemon: `loginuse`/`loginpas` are Foscam's actual CGI parameters
      // and contain neither `user` nor `pass`, so both reached
      // `popup.stream_failed` verbatim. `pw` and `p` are the same gap by
      // abbreviation. Enumerating names is whack-a-mole; the structure is not.
      for (final said in [
        'mse: streams: Get "http://127.0.0.1:9/cgi-bin/CGIProxy.fcgi'
            '?loginuse=admin&loginpas=$password": dial tcp 127.0.0.1:9: '
            'connect: connection refused',
        'mse: streams: Get "http://127.0.0.1:9/cgi-bin/mjpg/video.cgi'
            '?pw=$password": dial tcp 127.0.0.1:9: connect: connection refused',
        'mse: streams: Get "http://127.0.0.1:9/video?p=$password": dial tcp '
            '127.0.0.1:9: connect: connection refused',
        // Userinfo and a path-borne token, which no parameter-name rule ever
        // looked at, fall to the same structural cut.
        'mse: streams: Get "http://admin:$password@127.0.0.1:9/live": EOF',
        'mse: streams: Get "http://127.0.0.1:9/api/$password/live": EOF',
      ]) {
        final clean = redactCredentials(said);
        expect(clean, isNot(contains(password)), reason: said);
        expect(clean, isNot(contains('admin')), reason: said);
        // Which daemon, and what it said, both survive — the address is
        // rebuilt from scheme/host/port and the unquoted remainder is Go's,
        // not the operator's.
        expect(clean, contains('http://127.0.0.1:9'), reason: said);
        expect(clean, contains('mse: streams: Get'), reason: said);
        expect(clean, anyOf(contains('connection refused'), contains('EOF')),
            reason: said);
      }
    });

    test('the stream name inside a quoted URL goes too, because the log line '
        'already carries it as its own field', () {
      // This case used to be pinned as *unchanged*, on the ground that
      // `?src=` is the whole diagnostic. It is not lost: the Stream Director
      // logs `cameras.popup_failed name=cam_porch reason=…`, so the quoted
      // copy was a duplicate — and keeping the query string was the exception
      // that made the rule a guess about parameter names again.
      expect(
          redactCredentials(
              'streams: Get "http://127.0.0.1:1984/api/stream.mjpeg'
              '?src=cam_porch": connection refused'),
          'streams: Get "http://127.0.0.1:1984 <redacted>": connection '
              'refused');
    });

    test('a quoted string that is not a URL is left alone, so the rule cannot '
        'eat a sentence go2rtc put in quotes', () {
      for (final said in [
        'exec: "ffmpeg" not found in \$PATH',
        'streams: unsupported source "virtual camera"',
      ]) {
        expect(redactCredentials(said), said, reason: said);
      }
    });

    test('go2rtc\'s #key=value source options survive only where they are not '
        'hanging off a scheme://, which is the cost of the structural cut', () {
      // Stated as a loss rather than glossed. A fragment on a URL now goes
      // with the rest of the URL, options and all — the crude `=` rule that
      // used to keep them was the last guess in the file about what a URL
      // *means*, and it could not tell `#video=h264` from `#hunter2=`.
      expect(redactCredentials('streams: dial rtsp://cam/live#$password: EOF'),
          'streams: dial rtsp://cam <redacted>: EOF');
      expect(
          redactCredentials(
              'streams: rtsp://cam/live#media=video#backchannel=0: EOF'),
          'streams: rtsp://cam <redacted>: EOF');
      // And what still reads: go2rtc names its own producers without an
      // authority, which is the form this deployment's `selftest` takes.
      for (final said in [
        'exec: ffmpeg:selftest#video=h264 exited with status 1',
        'exec: ffmpeg:virtual?video&size=640x480#video=h264 exited',
      ]) {
        expect(redactCredentials(said), said, reason: said);
      }
    });

    test('every URL in the sentence goes, not just the first', () {
      expect(
          redactCredentials('rtsp://a:b@one/ failed over to rtsp://c:d@two/'),
          'rtsp://one <redacted> failed over to rtsp://two <redacted>');
    });

    test('an email address is left alone: it has no scheme in front of it and '
        'no user:pass pair inside it', () {
      expect(redactCredentials('mailto is not it: nobody@example.com'),
          'mailto is not it: nobody@example.com');
    });

    test('a URL that will not parse loses its address as well, rather than '
        'being vouched for by a rule that could not read it', () {
      // Safe, and less useful — the stated direction to be wrong in. There is
      // nothing to build an address up out of, so the whole run goes.
      expect(
          redactCredentials(
              'dial http://admin:$password@cam:notaport/live: refused'),
          'dial <redacted>: refused');
    });

    test('the one character trailing punctuation can leave behind is a '
        'character of the credential, and it is one', () {
      // Where the rule stops, pinned rather than described. `.,;:!?` at the
      // end of the run are treated as the sentence's, because ffmpeg ends its
      // line with `.` and Go separates URL from reason with `:` — so a
      // credential whose own last character is one of those leaves that one
      // character in the text.
      expect(redactCredentials('Error opening input file '
          'http://cam:9/live?p=$password.'),
          'Error opening input file http://cam:9 <redacted>.');
      // Same output, different truth: here the full stop was the password's.
      expect(redactCredentials('Error opening input file '
          'http://cam:9/live?p=$password..'),
          'Error opening input file http://cam:9 <redacted>..');
    });

    test('a trailing dot that really was part of a fully-qualified host is '
        'not lost, because the address is rebuilt rather than trimmed', () {
      // The other half of the same rule: the dot moves one character right,
      // and the text still says the same thing.
      expect(redactCredentials('dial rtsp://cam.local.: refused'),
          'dial rtsp://cam.local.: refused');
    });
  });

  group('what journald sees', () {
    late List<LogRecord> records;

    setUp(() {
      records = <LogRecord>[];
      Log.sink = records.add;
      Log.level = LogLevel.debug;
    });

    tearDown(() {
      Log.sink = Log.printRecord;
      Log.level = LogLevel.warn;
    });

    test('the rendered line is what carries no credential, not the return '
        'value — log.dart quotes and escapes on top of this', () {
      // Asserted against `LogRecord.toString()` because that is the artefact:
      // the redaction happens before `_render`, which then adds the quoting a
      // multi-line ffmpeg dump needs, and a rule that was safe before quoting
      // and not after would be a rule nobody had actually checked.
      Log.warn('cameras', 'popup_failed', {
        'name': 'cam_porch',
        'reason': redactCredentials(
            'go2rtc refused: mse: streams: exec/pipe: EOF\n'
            'Error opening input file http://127.0.0.1:9/video?p=$password.\n'),
      });

      final line = records.single.toString();
      expect(line, isNot(contains(password)));
      expect(line, startsWith('[panel] W cameras.popup_failed name=cam_porch '));
      expect(line, contains(r'Error opening input file http://127.0.0.1:9 '
          r'<redacted>.\n'));
    });
  });
}
