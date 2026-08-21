//! Hand-written macOS C bindings for the small surface transcribed needs.
//!
//! Zig 0.16's @cImport cannot resolve framework-style includes with this
//! CommandLineTools SDK layout, so we declare the stable ABIs directly.
//! Every constant here was verified against the SDK headers on disk.

const std = @import("std");

// --- core types -------------------------------------------------------------

pub const OSStatus = i32;
pub const FourCC = u32;

pub inline fn fourcc(comptime s: *const [4]u8) FourCC {
    return std.mem.readInt(u32, s, .big);
}

pub const Boolean = u8;
pub const UInt32_ = c_uint;

// --- Core Audio -------------------------------------------------------------

pub const AudioUnit = ?*anyopaque;
pub const AudioComponent = ?*anyopaque;
pub const AudioDeviceID = u32;
pub const AudioUnitElement = u32;
pub const AudioUnitScope = u32;
pub const AudioUnitPropertyID = u32;

pub const kAudioObjectSystemObject: AudioDeviceID = 1;

// Scopes (AudioUnitProperties.h:103-105)
pub const kAudioUnitScope_Global: AudioUnitScope = 0;
pub const kAudioUnitScope_Input: AudioUnitScope = 1;
pub const kAudioUnitScope_Output: AudioUnitScope = 2;

// Property IDs
pub const kAudioUnitProperty_StreamFormat: AudioUnitPropertyID = 8;
pub const kAudioOutputUnitProperty_CurrentDevice: AudioUnitPropertyID = 2000;
pub const kAudioOutputUnitProperty_EnableIO: AudioUnitPropertyID = 2003;
pub const kAudioOutputUnitProperty_SetInputCallback: AudioUnitPropertyID = 2005;

// Component type/subtype (AUComponent.h): Output='auou', HALOutput='ahal'
pub const kAudioUnitType_Output: FourCC = fourcc("auou");
pub const kAudioUnitSubType_HALOutput: FourCC = fourcc("ahal");

// Hardware property (AudioHardware.h)
pub const kAudioHardwarePropertyDefaultInputDevice: FourCC = fourcc("dIn ");

// Format flags (CoreAudioBaseTypes.h:524,527)
pub const kAudioFormatFlagIsFloat: u32 = 1 << 0;
pub const kAudioFormatFlagIsSignedInteger: u32 = 1 << 2;
pub const kAudioFormatFlagIsPacked: u32 = 1 << 3;
pub const kAudioFormatLinearPCM: FourCC = fourcc("lpcm");

pub const AudioStreamBasicDescription = extern struct {
    mSampleRate: f64,
    mFormatID: FourCC,
    mFormatFlags: u32,
    mBytesPerPacket: u32,
    mFramesPerPacket: u32,
    mBytesPerFrame: u32,
    mChannelsPerFrame: u32,
    mBitsPerChannel: u32,
    mReserved: u32,
};

pub const AudioBuffer = extern struct {
    mNumberChannels: u32,
    mDataByteSize: u32,
    mData: ?*anyopaque,
};

pub const AudioBufferList = extern struct {
    mNumberBuffers: u32,
    mBuffers: [1]AudioBuffer,
};

pub const AudioUnitRenderActionFlags = u32;
pub const AudioTimeStamp = opaque {};

pub const AURenderCallback = ?*const fn (
    inRefCon: ?*anyopaque,
    ioActionFlags: *AudioUnitRenderActionFlags,
    inTimeStamp: *const AudioTimeStamp,
    inBusNumber: u32,
    inNumberFrames: u32,
    ioData: ?*AudioBufferList,
) callconv(.c) OSStatus;

pub const AURenderCallbackStruct = extern struct {
    inputProc: AURenderCallback,
    inputProcRefCon: ?*anyopaque,
};

pub const AudioComponentDescription = extern struct {
    componentType: FourCC,
    componentSubType: FourCC,
    componentManufacturer: FourCC,
    componentFlags: u32,
    componentFlagsMask: u32,
};

pub const AudioObjectPropertyAddress = extern struct {
    mSelector: FourCC,
    mScope: FourCC,
    mElement: u32,
};

pub extern "c" fn AudioComponentFindNext(inAC: AudioComponent, inDesc: *const AudioComponentDescription) AudioComponent;
pub extern "c" fn AudioComponentInstanceNew(inDesc: AudioComponent, outInstance: *AudioUnit) OSStatus;
pub extern "c" fn AudioComponentInstanceDispose(instance: AudioUnit) OSStatus;
pub extern "c" fn AudioUnitInitialize(inUnit: AudioUnit) OSStatus;
pub extern "c" fn AudioUnitUninitialize(inUnit: AudioUnit) OSStatus;
pub extern "c" fn AudioUnitSetProperty(
    inUnit: AudioUnit,
    inID: AudioUnitPropertyID,
    inScope: AudioUnitScope,
    inElement: AudioUnitElement,
    inData: ?*const anyopaque,
    inDataSize: u32,
) OSStatus;
pub extern "c" fn AudioUnitGetProperty(
    inUnit: AudioUnit,
    inID: AudioUnitPropertyID,
    inScope: AudioUnitScope,
    inElement: AudioUnitElement,
    outData: ?*anyopaque,
    ioDataSize: *u32,
) OSStatus;
pub extern "c" fn AudioOutputUnitStart(ci: AudioUnit) OSStatus;
pub extern "c" fn AudioOutputUnitStop(ci: AudioUnit) OSStatus;
pub extern "c" fn AudioUnitRender(
    inUnit: AudioUnit,
    ioActionFlags: *AudioUnitRenderActionFlags,
    inTimeStamp: *const AudioTimeStamp,
    inOutputBusNumber: u32,
    inNumberFrames: u32,
    ioData: ?*AudioBufferList,
) OSStatus;
pub extern "c" fn AudioObjectGetPropertyData(
    inObjectID: AudioDeviceID,
    inAddress: *const AudioObjectPropertyAddress,
    inQualifierDataSize: u32,
    inQualifierData: ?*const anyopaque,
    ioDataSize: *u32,
    outData: *anyopaque,
) OSStatus;

// --- Carbon hotkey -----------------------------------------------------------

pub const EventHotKeyRef = ?*anyopaque;
pub const EventHandlerRef = ?*anyopaque;
pub const EventTargetRef = ?*anyopaque;
pub const EventHandlerCallRef = ?*anyopaque;
pub const EventRef = ?*anyopaque;

pub const kEventClassKeyboard: u32 = fourcc("keyb");
pub const kEventHotKeyPressed: u32 = 5;
pub const kEventHotKeyReleased: u32 = 6;

// Virtual key codes (Events.h)
pub const kVK_Space: u32 = 0x31;
pub const kVK_ANSI_V: u32 = 0x09;

// Modifier masks (Events.h:111-131): controlKey = 1 << 12
pub const cmdKey: u32 = 1 << 8;
pub const shiftKey: u32 = 1 << 9;
pub const optionKey: u32 = 1 << 11;
pub const controlKey: u32 = 1 << 12;

pub const EventTypeSpec = extern struct {
    eventClass: u32,
    eventKind: u32,
};

pub const EventHotKeyID = extern struct {
    signature: FourCC,
    hotKeyID: u32,
};

pub const EventHandlerUPP = ?*const fn (
    inHandlerCallRef: EventHandlerCallRef,
    inEvent: EventRef,
    inUserData: ?*anyopaque,
) callconv(.c) OSStatus;

pub extern "c" fn InstallEventHandler(
    inTarget: EventTargetRef,
    inHandler: EventHandlerUPP,
    inNumTypes: u32,
    inList: [*]const EventTypeSpec,
    inUserData: ?*anyopaque,
    outRef: ?*EventHandlerRef,
) OSStatus;
pub extern "c" fn RegisterEventHotKey(
    inHotKeyCode: u32,
    inHotKeyModifiers: u32,
    inHotKeyID: EventHotKeyID,
    inTarget: EventTargetRef,
    inOptions: u32,
    outRef: ?*EventHotKeyRef,
) OSStatus;
pub extern "c" fn GetApplicationEventTarget() EventTargetRef;
pub extern "c" fn GetEventKind(inEvent: EventRef) u32;
pub extern "c" fn RunApplicationEventLoop() void;

// --- Core Foundation / pasteboard / CGEvent -----------------------------------

pub const CFStringRef = ?*anyopaque;
pub const CFDataRef = ?*anyopaque;
pub const CFAllocatorRef = ?*anyopaque;
pub const PasteboardRef = ?*anyopaque;
pub const CGEventRef = ?*anyopaque;
pub const CGEventFlags = u64;

pub const kCFStringEncodingUTF8: u32 = 0x0800_0100;
pub const kCFAllocatorDefault: CFAllocatorRef = null;
pub const kPasteboardClipboard = "com.apple.pasteboard.clipboard";
pub const kUTTypeUTF8PlainText = "public.utf8-plain-text";

pub const kCGHIDEventTap: u32 = 0;
pub const kCGEventKeyDown: u32 = 10;
pub const kCGEventKeyUp: u32 = 11;
pub const kCGEventFlagMaskCommand: CGEventFlags = 0x0010_0000;

pub extern "c" fn CFStringCreateWithCString(
    alloc: CFAllocatorRef,
    cStr: [*:0]const u8,
    encoding: u32,
) CFStringRef;
pub extern "c" fn CFDataCreate(
    alloc: CFAllocatorRef,
    bytes: [*]const u8,
    length: isize,
) CFDataRef;
pub extern "c" fn CFRelease(cf: ?*anyopaque) void;

pub extern "c" fn PasteboardCreate(inName: CFStringRef, outPasteboard: *PasteboardRef) OSStatus;
pub extern "c" fn PasteboardClear(pasteboard: PasteboardRef) OSStatus;
pub extern "c" fn PasteboardPutItemFlavor(
    pasteboard: PasteboardRef,
    itemID: u64,
    flavorType: CFStringRef,
    flavorData: CFDataRef,
    flags: u32,
) OSStatus;

pub extern "c" fn CGEventCreateKeyboardEvent(
    allocator: ?*anyopaque,
    virtualKey: u16,
    keyDown: bool,
) CGEventRef;
pub extern "c" fn CGEventSetFlags(event: CGEventRef, flags: CGEventFlags) void;
pub extern "c" fn CGEventPost(tapLocation: u32, event: CGEventRef) void;

test "fourcc values match SDK" {
    try std.testing.expectEqual(@as(u32, 0x6175_6F75), kAudioUnitType_Output); // 'auou'
    try std.testing.expectEqual(@as(u32, 0x6168_616C), kAudioUnitSubType_HALOutput); // 'ahal'
    try std.testing.expectEqual(@as(u32, 0x6C70_636D), kAudioFormatLinearPCM); // 'lpcm'
    try std.testing.expectEqual(@as(u32, 0x6449_6E20), kAudioHardwarePropertyDefaultInputDevice); // 'dIn '
    try std.testing.expectEqual(@as(u32, 0x6B65_7962), kEventClassKeyboard); // 'keyb'
}
