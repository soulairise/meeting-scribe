import CoreAudio
import Foundation

enum CA {
    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T>(_ objectID: AudioObjectID,
                         _ selector: AudioObjectPropertySelector,
                         scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                         default defaultValue: T) throws -> T {
        var addr = address(selector, scope: scope)
        var size = UInt32(MemoryLayout<T>.size)
        var result = defaultValue
        let status = withUnsafeMutableBytes(of: &result) {
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else {
            throw CaptureError.coreAudio("속성 읽기 실패 (selector \(fourCC(selector)))", status)
        }
        return result
    }

    static func string(_ objectID: AudioObjectID,
                       _ selector: AudioObjectPropertySelector) throws -> String {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: CFString? = nil
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value else {
            throw CaptureError.coreAudio("문자열 속성 읽기 실패 (selector \(fourCC(selector)))", status)
        }
        return value as String
    }

    /// 가변 길이 속성(예: 스트림 포맷)을 바이트로 읽어 원하는 타입으로 해석한다.
    static func variableValue<T>(_ objectID: AudioObjectID,
                                 _ selector: AudioObjectPropertySelector,
                                 as type: T.Type) throws -> T {
        var addr = address(selector)
        var size: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(objectID, &addr, 0, nil, &size)
        guard status == noErr, size >= UInt32(MemoryLayout<T>.size) else {
            throw CaptureError.coreAudio("속성 크기 조회 실패 (selector \(fourCC(selector)))", status)
        }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<T>.alignment)
        defer { raw.deallocate() }
        status = AudioObjectGetPropertyData(objectID, &addr, 0, nil, &size, raw)
        guard status == noErr else {
            throw CaptureError.coreAudio("속성 읽기 실패 (selector \(fourCC(selector)))", status)
        }
        return raw.load(as: T.self)
    }

    static func defaultOutputDevice() throws -> AudioDeviceID {
        try value(AudioObjectID(kAudioObjectSystemObject),
                  kAudioHardwarePropertyDefaultOutputDevice,
                  default: AudioDeviceID(0))
    }

    static func fourCC(_ v: AudioObjectPropertySelector) -> String {
        let bytes = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        return String(bytes: bytes, encoding: .ascii) ?? "\(v)"
    }
}
