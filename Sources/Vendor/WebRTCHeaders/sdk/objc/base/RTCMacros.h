/*
 * WebRTC header shim for SwiftPM builds.
 *
 * Some WebRTC binary distributions ship public headers that reference the
 * original source-tree path `"sdk/objc/base/RTCMacros.h"` but do not include
 * that path inside the framework bundle.
 *
 * We provide a minimal wrapper so those includes resolve during module import.
 */
 
#pragma once
 
#import <WebRTC/RTCMacros.h>

