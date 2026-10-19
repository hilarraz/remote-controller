import Foundation
import Testing
@testable import AppleTVKit

@Suite struct ProtobufTests {
    @Test func roundTripsScalarsAndMessages() throws {
        var writer = ProtoWriter()
        writer.uint(1, 300)
        writer.string(2, "héllo")
        writer.double(14, 190.5)
        writer.bool(19, true)
        writer.message(3) { $0.string(1, "inner") }
        let message = try #require(ProtoMessage(writer.data))
        #expect(message.uint(1) == 300)
        #expect(message.string(2) == "héllo")
        #expect(message.double(14) == 190.5)
        #expect(message.bool(19) == true)
        #expect(message.message(3)?.string(1) == "inner")
    }

    @Test func splitsLengthPrefixedMessages() {
        let first = MRPMessages.setConnectionState()
        let second = MRPMessages.getKeyboardSession()
        let framed = ProtoWriter.varint(UInt64(first.count)) + first + ProtoWriter.varint(UInt64(second.count)) + second
        let messages = NowPlayingSession.splitProtobufs(framed)
        #expect(messages.map { $0.uint(1) } == [38, 24])
        // A lone message is sent without its length prefix.
        #expect(NowPlayingSession.splitProtobufs(first).first?.uint(1) == 38)
    }

    @Test func encodesSeekCommand() throws {
        let message = try #require(ProtoMessage(MRPMessages.seek(to: 754.5)))
        #expect(message.uint(1) == 1)
        let command = try #require(message.message(6))
        #expect(command.uint(1) == 45)
        #expect(command.message(2)?.double(9) == 754.5)
    }
}

@Suite struct HTTPMessageTests {
    @Test func parsesPipelinedResponses() throws {
        var buffer = Data("RTSP/1.0 200 OK\r\nContent-Length: 3\r\nCSeq: 1\r\n\r\nabcRTSP/1.0 200 OK\r\nCSeq: 2\r\n\r\n".utf8)
        let first = try #require(HTTPMessage.parse(from: &buffer))
        #expect(first.statusCode == 200)
        #expect(first.header("cseq") == "1")
        #expect(first.body == Data("abc".utf8))
        let second = try #require(HTTPMessage.parse(from: &buffer))
        #expect(second.header("CSeq") == "2")
        #expect(buffer.isEmpty)
    }

    @Test func waitsForTheWholeBody() {
        let partial = Data("HTTP/1.1 200 OK\r\nContent-Length: 10\r\n\r\nabc".utf8)
        var buffer = partial
        #expect(HTTPMessage.parse(from: &buffer) == nil)
        #expect(buffer == partial)
    }
}

@Suite struct NowPlayingTrackerTests {
    private func protocolMessage(type: Int, field: Int, _ build: (inout ProtoWriter) -> Void) -> ProtoMessage {
        var writer = ProtoWriter()
        writer.uint(1, UInt64(type))
        writer.message(field, build)
        return ProtoMessage(writer.data)!
    }

    private func playerPath(_ writer: inout ProtoWriter, field: Int) {
        writer.message(field) { path in
            path.message(2) { client in
                client.string(2, "com.apple.TVMusic")
                client.string(7, "Musique")
            }
            path.message(3) { $0.string(1, "MediaRemote-DefaultPlayer") }
        }
    }

    @Test func reportsThePlayingItem() throws {
        let tracker = NowPlayingTracker()
        _ = tracker.handle(protocolMessage(type: 46, field: 50) { inner in
            inner.message(1) { $0.string(2, "com.apple.TVMusic") }
        }, type: 46)
        let changed = tracker.handle(protocolMessage(type: 4, field: 9) { state in
            state.message(3) { queue in
                queue.int(1, 0)
                queue.message(2) { item in
                    item.string(1, "item-1")
                    item.message(2) { metadata in
                        metadata.string(1, "Benef")
                        metadata.string(7, "DKN")
                        metadata.double(14, 190.6)
                        metadata.double(35, 12)
                        metadata.string(80, "https://example.com/{w}x{h}{c}.{f}")
                    }
                }
            }
            state.uint(6, 1)
            playerPath(&state, field: 9)
        }, type: 4)

        #expect(changed)
        let info = tracker.current
        #expect(info?.title == "Benef")
        #expect(info?.subtitle == "DKN")
        #expect(info?.appName == "Musique")
        #expect(info?.duration == 190.6)
        #expect(info?.isPlaying == true)
        #expect(info?.artworkURL?.absoluteString == "https://example.com/600x600bb.jpg")
        #expect(info?.canSeek == false)

        // Seeking becomes available once the client's default commands allow it.
        _ = tracker.handle(protocolMessage(type: 72, field: 75) { defaults in
            defaults.message(2) { commands in
                commands.message(1) { $0.uint(1, 45); $0.bool(2, true) }
                commands.message(1) { $0.uint(1, 46); $0.bool(2, false) }
            }
            playerPath(&defaults, field: 9)
        }, type: 72)
        #expect(tracker.current?.canSeek == true)

        // The answer to our queue request adds the audio tracks and subtitles.
        func option(_ writer: inout ProtoWriter, type: UInt64, tag: String, name: String) {
            writer.message(3) { language in
                language.uint(1, type)
                language.string(2, tag)
                language.string(4, name)
                language.string(5, "\(type)-\(tag)")
            }
        }
        _ = tracker.handle(protocolMessage(type: 4, field: 9) { state in
            state.message(3) { queue in
                queue.message(2) { item in
                    item.string(1, "item-1")
                    item.message(5) { group in
                        option(&group, type: 0, tag: "fr", name: "Français")
                        option(&group, type: 0, tag: "ja", name: "Japonais")
                    }
                    item.message(5) { group in
                        group.bool(1, true)
                        option(&group, type: 1, tag: "fr", name: "Français")
                    }
                    item.message(6) { language in
                        language.uint(1, 0)
                        language.string(5, "0-ja")
                    }
                }
            }
            state.message(10) { $0.int(1, 0) }
            playerPath(&state, field: 9)
        }, type: 4)
        let groups = tracker.current?.languageGroups ?? []
        #expect(groups.map(\.kind) == [.audio, .subtitles])
        #expect(groups.first?.options.map(\.title) == ["Français", "Japonais"])
        #expect(groups.last?.allowsEmptySelection == true)
        #expect(tracker.current?.currentLanguageOptions.map(\.identifier) == ["0-ja"])
        #expect(tracker.current?.title == "Benef")

        let japanese = try #require(groups.first?.options.last)
        let command = try #require(ProtoMessage(MRPMessages.languageCommand(japanese, enable: true))?.message(6))
        #expect(command.uint(1) == 53)
        #expect(command.message(2)?.message(27)?.string(5) == "0-ja")

        // Pausing keeps the item but stops the progress.
        _ = tracker.handle(protocolMessage(type: 4, field: 9) { state in
            state.uint(6, 2)
            playerPath(&state, field: 9)
        }, type: 4)
        #expect(tracker.current?.isPlaying == false)
        #expect(tracker.current?.title == "Benef")
    }
}
