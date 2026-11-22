"""Run the native client against an ephemeral loopback HTTP fixture."""
import http.server
import json
import os
import subprocess
import sys
import threading
import urllib.parse


class Handler(http.server.BaseHTTPRequestHandler):
    subtitle_polls = None
    def do_POST(self):
        valid = self.path.split("?", 1)[0] == "/playQueues"
        body = b'<MediaContainer playQueueID="55" playQueueSelectedItemID="701" playQueueTotalCount="2"><Video type="movie" ratingKey="42" playQueueItemID="701" title="First"/><Video type="movie" ratingKey="99" playQueueItemID="702" title="Second"/></MediaContainer>'
        if self.path.split("?", 1)[0] == "/livetv/dvrs/1/channels/2.1/tune":
            valid = True
            body = b'<MediaContainer><Metadata live="1"><Media uuid="dc30f95e-6379-44f7-8168-172ffc820496"><Part><Stream codec="mpeg2video" streamType="1"/></Part></Media></Metadata></MediaContainer>'
        if self.path.split("?", 1)[0] == "/media/subscriptions":
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            valid = query == {"hints[guid]":["plex://episode/fixture"], "params[mediaProviderID]":["1"], "targetLibrarySectionID":["2"], "targetSectionLocationID":["2"], "type":["4"]}
            body = b'<MediaContainer/>'
        if self.path.split("?", 1)[0] == "/:/timeline":
            valid = self.headers.get("X-Plex-Session-Identifier") == "timeline-fixture"
            body = b'<MediaContainer/>'
        if self.path.split("?", 1)[0] == "/playlists":
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            valid = query == {"uri": ["server://fixture123/com.plexapp.plugins.library/library/metadata/99"], "type": ["video"], "smart": ["0"], "title": ["Fixture list"]}
            body = b'<MediaContainer><Playlist ratingKey="56" type="playlist" title="Fixture list"/></MediaContainer>'
        self.send_response(200 if valid else 400)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_PUT(self):
        query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
        valid = self.path.split("?", 1)[0] == "/library/parts/991" and query == {"subtitleStreamID": ["993"], "allParts": ["1"]}
        if self.path.split("?", 1)[0] == "/media/subscriptions/7" and query == {"prefs[newnessPolicy]": ["1"]}:
            valid = True
        if self.path.split("?", 1)[0] == "/playQueues/77/items/1000/move" and query == {"after": ["1001"]}:
            valid = True
        if self.path.split("?", 1)[0] == "/playlists/55/items/701/move" and query == {"after": ["702"]}:
            valid = True
        if self.path.split("?", 1)[0] == "/playlists/55" and query == {"title": ["Renamed fixture"]}:
            valid = True
        if self.path.split("?", 1)[0] == "/playlists/55/items" and query == {"uri": ["server://fixture123/com.plexapp.plugins.library/library/metadata/99"]}:
            valid = True
        if self.path.split("?", 1)[0] == "/library/metadata/99/subtitles" and query == {"key": ["/library/streams/994"]}:
            valid = True
            Handler.subtitle_polls = 0
        self.send_response(200 if valid else 400)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_DELETE(self):
        valid = self.path in ("/playQueues/77/items/1000", "/playlists/55/items/701", "/playlists/55", "/media/subscriptions/7")
        self.send_response(200 if valid else 400)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def do_GET(self):
        status = 200
        headers = {}
        if self.path.startswith("/video/:/transcode/universal/start.m3u8?"):
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            live = query.get("path") == ["/livetv/sessions/dc30f95e-6379-44f7-8168-172ffc820496"]
            if query.get("path") == ["/library/metadata/100"]:
                assert query.get("mediaIndex") == ["1"]
                body = ("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=3500000\nhttps://127.0.0.1:%d/video/:/transcode/universal/session/version-fixture/index.m3u8\n" % self.server.server_port).encode()
            elif query.get("path") == ["/library/metadata/42"]:
                body = ("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=3500000\nhttps://127.0.0.1:%d/video/:/transcode/universal/session/queue-fixture/index.m3u8\n" % self.server.server_port).encode()
            elif live:
                assert query.get("directPlay") == ["0"] and query.get("protocol") == ["hls"]
                body = ("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=3500000\nhttps://127.0.0.1:%d/video/:/transcode/universal/session/live-fixture/index.m3u8\n" % self.server.server_port).encode()
            else:
                status, body = 404, b""
        elif self.path == "/media/providers":
            body = json.dumps({"MediaContainer":{"MediaProvider":[{"title":"Fixture Guide","Feature":[{"type":"grid","key":"/tv.plex.providers.epg.cloud:1/grid"},{"type":"grid","key":"https://invalid.test/grid"}]}]}}).encode()
        elif self.path == "/tv.plex.providers.epg.cloud:1/lineups/dvr/channels":
            body = json.dumps({"MediaContainer":{"Channel":[{"title":"Fixture TV","gridKey":"channel-one"}]}}).encode()
        elif self.path.startswith("/tv.plex.providers.epg.cloud:1/grid?"):
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            assert query.get("channelGridKey") == ["channel-one"] and len(query.get("date",[""])[0]) == 10
            body = json.dumps({"MediaContainer":{"Metadata":[{"title":"Episode","grandparentTitle":"Fixture Show","guid":"plex://episode/fixture","summary":"A scheduled fixture episode","Media":[{"beginsAt":2000000000,"endsAt":2000001800}]}]}}).encode()
        elif self.path.startswith("/media/subscriptions/template?"):
            body = json.dumps({"MediaContainer":{"SubscriptionTemplate":[{"MediaSubscription":[{"title":"This episode","type":4,"parameters":"hints%5Bguid%5D=plex%3A%2F%2Fepisode%2Ffixture&params%5BmediaProviderID%5D=1"}]}]}}).encode()
        elif self.path == "/library/sections" and self.headers.get("Accept") == "application/json":
            body = json.dumps({"MediaContainer":{"Directory":[{"key":"1","title":"Movies","type":"movie","Location":[{"id":1}]},{"key":"2","title":"TV Shows","type":"show","Location":[{"id":2}]}]}}).encode()
        elif self.path == "/media/subscriptions":
            body = b'{"MediaContainer":{"MediaSubscription":[{"key":"7","title":"Fixture recording","Setting":[{"id":"newnessPolicy","label":"Record","enumValues":"0:All episodes|1:New episodes","value":0}]}]}}'
        elif self.path == "/media/subscriptions/scheduled":
            body = b'{"MediaContainer":{"MediaGrabOperation":[{"status":"scheduled","Metadata":{"grandparentTitle":"Fixture Series","title":"Next episode","summary":"Scheduled recording","Media":[{"beginsAt":1795345200}]}}]}}'
        elif self.path == "/livetv/dvrs":
            body = b'{"MediaContainer":{"Dvr":[]}}'
        elif self.path.startswith("/playQueues/77?"):
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            center = int(query.get("center", ["1121"])[0]) - 1000
            start, end = max(0, center-50), min(243, center+51)
            body = ('<MediaContainer playQueueTotalCount="243">' + ''.join('<Video type="movie" ratingKey="%d" playQueueItemID="%d" title="Queue movie %d"/>' % (5000+i,1000+i,i) for i in range(start,end)) + '</MediaContainer>').encode()
        elif self.path == "/identity":
            body = b'<MediaContainer version="1.2.3" machineIdentifier="fixture123"/>'
        elif self.path.split("?", 1)[0] == "/catalog-pages":
            start = int(self.headers.get("X-Plex-Container-Start", "0"))
            end = min(start + 100, 243)
            body = (f'<MediaContainer offset="{start}" totalSize="243">' +
                    ''.join(f'<Video title="Movie {i}" type="movie" ratingKey="{i}"/>'
                            for i in range(start, end)) + '</MediaContainer>').encode()
        elif self.path.split("?", 1)[0] == "/playQueues/55":
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            content = b'<Video ratingKey="99" playQueueItemID="702"/>'
            if query.get("center") == ["701"] or query.get("window") == ["50"]:
                content = b'<Video ratingKey="42" playQueueItemID="701"/>' + content
            body = b'<MediaContainer>' + content + b'</MediaContainer>'
        elif self.path.split("?", 1)[0] == "/playlists":
            body = b'<MediaContainer><Playlist type="playlist" playlistType="video" ratingKey="55" title="Video list"/><Playlist type="playlist" playlistType="audio" ratingKey="57" title="Audio list"/><Playlist type="playlist" playlistType="video" smart="1" ratingKey="58" title="Smart list"/></MediaContainer>'
        elif self.path.split("?", 1)[0] == "/playlists/55":
            body = b'<MediaContainer><Playlist type="playlist" playlistType="video" ratingKey="55" title="Video list" smart="0"/></MediaContainer>'
        elif self.path.split("?", 1)[0] == "/playlists/56/items":
            body = b'<MediaContainer size="0"/>'
        elif self.path.split("?", 1)[0] == "/playlists/55/items":
            body = b'<MediaContainer totalSize="2"><Video title="First" type="movie" ratingKey="42" playlistItemID="701"/><Video title="Second" type="movie" ratingKey="99" playlistItemID="702"/></MediaContainer>'
        elif self.path.split("?", 1)[0] == "/library/sections":
            body = (b'<MediaContainer><Directory title="Movies" type="movie" key="1" '
                    b'viewOffset="42000" viewCount="1"/>'
                    b'<Directory title="TV Shows" type="show" key="2"/></MediaContainer>')
        elif self.path.split("?", 1)[0] == "/library/sections/watchlist/all":
            body = b'{"MediaContainer":{"librarySectionTitle":"Fixture Watchlist","size":1,"totalSize":1,"Metadata":[{"guid":"plex://movie/0123456789abcdef01234567","ratingKey":"0123456789abcdef01234567","title":"Fixture Movie","year":2024,"type":"movie"}]}}'
        elif self.path.split("?", 1)[0] == "/library/search":
            body = b'{"MediaContainer":{"SearchResults":[{"id":"external","SearchResult":[{"Metadata":{"guid":"plex://movie/0123456789abcdef01234567","title":"Fixture Movie","year":2024,"type":"movie"}},{"Metadata":null},null]},{"id":"other","SearchResult":[]}]}}'
        elif self.path.split("?", 1)[0] == "/library/metadata/99/subtitles":
            body = b'<MediaContainer><Stream key="/library/streams/994" title="Turkish release subtitle" language="Turkish"/><Stream key="/invalid/995" title="Invalid"/></MediaContainer>'
        elif self.path.split("?", 1)[0] == "/library/all":
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            body = b'<MediaContainer><Video title="Fixture Movie" type="movie" ratingKey="42"/></MediaContainer>'
            if "title" in query:
                body = b'<MediaContainer totalSize="3" offset="0"><Video title="Fixture Movie" type="movie" ratingKey="42"/><Directory title="Fixture Series" type="show" ratingKey="60"/><Video title="Fixture Episode" grandparentTitle="Fixture Series" type="episode" ratingKey="61" grandparentRatingKey="60"/></MediaContainer>'
        elif self.path.split("?", 1)[0] == "/hubs/promoted":
            body = (b'<MediaContainer><Hub title="Plex Continue" hubIdentifier="home.continue" '
                    b'key="/hubs/home/continueWatching"><Video title="Episode 8" type="episode" '
                    b'ratingKey="70" grandparentTitle="Fixture Series" parentIndex="1" index="8"/>'
                    b'</Hub><Hub title="Fresh from Plex" hubIdentifier="movie.recentlyadded.1">'
                    b'<Video title="Fixture Movie" type="movie" ratingKey="42"/></Hub></MediaContainer>')
        elif self.path.split("?", 1)[0] == "/hubs/search":
            query = urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)
            if query != {"query": ["Ç A"], "limit": ["100"]}:
                status, body = 400, b"<MediaContainer/>"
            else:
                body = (b'<MediaContainer><Hub type="movie"><Video title="Fixture Movie" type="movie" ratingKey="42"/>'
                        b'</Hub><Hub type="show"><Directory title="Fixture Series" type="show" ratingKey="60"/>'
                        b'</Hub></MediaContainer>')
        elif self.path.split("?", 1)[0] == "/library/sections/1/genre":
            if set(urllib.parse.parse_qs(urllib.parse.urlsplit(self.path).query)) - {"X-Plex-Container-Start", "X-Plex-Container-Size"}:
                status, body = 400, b"<MediaContainer/>"
            else:
                body = b'<MediaContainer><Directory title="Drama" key="7"/><Directory title="Comedy" key="8"/></MediaContainer>' 
        elif self.path.split("?", 1)[0] == "/library/sections/1/all":
            body = b'<MediaContainer><Video title="Fixture Movie" type="movie" ratingKey="42"/></MediaContainer>'
        elif self.path.split("?", 1)[0] == "/library/metadata/71":
            body = b'<MediaContainer><Video type="movie" ratingKey="71" title="Resume fixture" duration="60000" viewOffset="12000"><Media videoCodec="h264" audioCodec="aac"><Part id="710" key="/library/parts/710/file.mp4"/></Media></Video></MediaContainer>'
        elif self.path.split("?", 1)[0] == "/library/metadata/42":
            body = (b'<MediaContainer><Video title="Fixture Movie" year="2024" type="movie" '
                    b'duration="3600000" viewOffset="42000" viewCount="1" summary="Fixture summary"/></MediaContainer>')
        elif self.path.split("?", 1)[0] == "/library/metadata/100/children":
            body = (b'<MediaContainer><Photo title="Landscape" type="photo" ratingKey="101" '
                    b'thumb="/library/metadata/101/thumb/1"/></MediaContainer>')
        elif self.path.split("?", 1)[0] == "/library/metadata/101":
            body = (b'<MediaContainer><Photo title="Landscape" type="photo" ratingKey="101" '
                    b'thumb="/library/metadata/101/thumb/1"/></MediaContainer>')
        elif self.path.split("?", 1)[0] == "/library/metadata/60":
            body = b'<MediaContainer><Directory type="show" title="Fixture Series" ratingKey="60"><Role id="123" tag="An Actor" role="A role"/></Directory></MediaContainer>'
        elif self.path.split("?", 1)[0] == "/library/metadata/64":
            body = b'<MediaContainer><Video type="episode" ratingKey="64" grandparentRatingKey="60"/></MediaContainer>'
        elif self.path.split("?", 1)[0] == "/library/metadata/65":
            body = b'<MediaContainer><Directory type="season" ratingKey="65"/></MediaContainer>'
        elif self.path.split("?", 1)[0] == "/library/metadata/66":
            body = b'<MediaContainer><Video type="episode" ratingKey="66" grandparentRatingKey="60"><Role id="124" tag="Guest Actor" role="Guest"/></Video></MediaContainer>'
        elif self.path.split("?", 1)[0] == "/library/metadata/61":
            body = b'<MediaContainer><Directory type="season" title="Season 1" parentTitle="Fixture Series" ratingKey="61" parentRatingKey="60" summary="Season summary"/></MediaContainer>'
        elif self.path.split("?", 1)[0] == "/library/metadata/61/children":
            body = (b'<MediaContainer><Video type="episode" title="Pilot" grandparentTitle="Fixture Series" ratingKey="62" parentIndex="1" index="1" viewCount="1"/>'
                    b'<Video type="episode" title="Second" grandparentTitle="Fixture Series" ratingKey="63" parentIndex="1" index="2" viewOffset="42000" duration="1200000"/></MediaContainer>')
        elif self.path.split("?", 1)[0] == "/library/metadata/100":
            body = b'<MediaContainer><Video title="Versions" type="movie" ratingKey="100"><Media width="3840" videoCodec="hevc" audioCodec="truehd" videoResolution="4k"><Part id="1000"/></Media><Media width="1920" videoCodec="h264" audioCodec="aac" videoResolution="1080" optimizedForStreaming="1"><Part id="1001"><Stream id="1002" streamType="2" displayTitle="AAC"/></Part></Media></Video></MediaContainer>'
        elif self.path.split("?", 1)[0] == "/library/metadata/99":
            body = (b'<MediaContainer><Video title="Stream fixture" type="movie" ratingKey="99">'
                    b'<Genre tag="Drama"/><Role id="123" tag="An Actor" role="A role"/>'
                    b'<Chapter index="1" startTimeOffset="62500" endTimeOffset="120000" title="Opening"/>'
                    b'<Marker type="intro" startTimeOffset="1000" endTimeOffset="15000"/>'
                    b'<Extras><Video title="Trailer" type="clip" ratingKey="98"/></Extras>' 
                    b'<Media videoCodec="hevc" audioCodec="dca"><Part id="991" key="/library/parts/991/file.mkv">'
                    b'<Stream id="992" streamType="2" displayTitle="English (DTS 5.1)" selected="1"/>'
                    b'<Stream id="993" streamType="3" displayTitle="Turkish (SRT)" codec="srt"/>'
                    b'</Part></Media></Video></MediaContainer>')
            if Handler.subtitle_polls is not None:
                Handler.subtitle_polls += 1
                if Handler.subtitle_polls >= 3:
                    body = body.replace(b'</Part>', b'<Stream id="994" key="/library/streams/994" streamType="3" title="Downloaded"/></Part>')
        elif self.path == "/redirect":
            status, body = 302, b""
            headers["Location"] = "/identity"
        elif self.path == "/oversized":
            body = b""
            headers["Content-Length"] = str(1024 * 1024 + 1)
        else:
            body = b'<!DOCTYPE MediaContainer><MediaContainer/>'
        self.send_response(status)
        self.send_header("Content-Type", "application/xml")
        headers.setdefault("Content-Length", str(len(body)))
        for key, value in headers.items():
            self.send_header(key, value)
        self.end_headers()
        if body:
            self.wfile.write(body)

    def log_message(self, format, *args):
        pass


with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler) as server:
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        origin = f"http://127.0.0.1:{server.server_port}"
        if len(sys.argv) == 2:
            subprocess.run([sys.argv[1], origin], check=True)
        else:
            subprocess.run(sys.argv[1:], env={**os.environ, "REVIVEPLEX_TEST_ORIGIN": origin}, check=True)
    finally:
        server.shutdown()
        thread.join()
