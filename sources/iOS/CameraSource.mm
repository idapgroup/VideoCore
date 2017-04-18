/*
 
 Video Core
 Copyright (c) 2014 James G. Hurley
 
 Permission is hereby granted, free of charge, to any person obtaining a copy
 of this software and associated documentation files (the "Software"), to deal
 in the Software without restriction, including without limitation the rights
 to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 copies of the Software, and to permit persons to whom the Software is
 furnished to do so, subject to the following conditions:
 
 The above copyright notice and this permission notice shall be included in
 all copies or substantial portions of the Software.
 
 THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
 THE SOFTWARE.
 
 */

#include <videocore/sources/iOS/CameraSource.h>
#include <videocore/mixers/IVideoMixer.hpp>
#include <videocore/system/pixelBuffer/Apple/PixelBuffer.h>

#include <glm/glm.hpp>
#include <glm/gtc/matrix_transform.hpp>

#import <videocore/sources/iOS/Categories/AVCaptureSession+VCExtensions.h>
#import <videocore/sources/iOS/Categories/AVCaptureDevice+VCExtensions.h>

@interface sbCallback: NSObject<AVCaptureVideoDataOutputSampleBufferDelegate> {
    std::weak_ptr<videocore::iOS::CameraSource> m_source;
}

- (void) setSource:(std::weak_ptr<videocore::iOS::CameraSource>) source;

@end

@implementation sbCallback

- (void)setSource:(std::weak_ptr<videocore::iOS::CameraSource>)source {
    m_source = source;
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection
{
    auto source = m_source.lock();
    if (source && source->isConnectionForCurrentInput(connection)) {
        source->bufferCaptured(sampleBuffer);
    }
}

- (void) captureOutput:(AVCaptureOutput *)captureOutput
   didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
        fromConnection:(AVCaptureConnection *)connection
{
}

- (void) orientationChanged: (NSNotification*) notification
{
    auto source = m_source.lock();
    if (source && !source->orientationLocked()) {
        dispatch_async(dispatch_get_global_queue(0, 0), ^{
            source->reorientCamera();
        });
    }
}

@end

namespace videocore { namespace iOS {
    
    CameraSource::CameraSource()
    :
    m_matrix(glm::mat4(1.f)),
    m_orientationLocked(false),
    m_torchOn(false),
    m_isFront(false),
    m_useInterfaceOrientation(false),
    m_inputs(nullptr)
    {}
    
    CameraSource::~CameraSource() {
        setInputs(nil);
    }
    
    void CameraSource::setup(AVCaptureSession *session, int fps, bool useFront, bool useInterfaceOrientation) {
        m_fps = fps;
        m_useInterfaceOrientation = useInterfaceOrientation;
        m_isFront = useFront;
        
        CaptureSessionSource::setup(session);
    }

    void CameraSource::setupCaptureSessionConnections() {
        NSMutableArray *inputs = [NSMutableArray array];
        
        id input = setupCaptureInputWithCameraPosition(AVCaptureDevicePositionFront);
        [inputs addObject:input];
        
        input = setupCaptureInputWithCameraPosition(AVCaptureDevicePositionBack);
        [inputs addObject:input];
        
        addCaptureInput(input);
        setCaptureInput(input);

        setInputs([[inputs copy] autorelease]);
        
        setupCaptureOutput();
        
        reorientCamera();
    }
    
    AVCaptureDeviceInput *CameraSource::setupCaptureInputWithCameraPosition(int position) {
        AVCaptureDevice *device = cameraWithPosition(position);
        [device configureWithBlock:^(AVCaptureDevice *device) {
            CMTime duration = frameDuration();
            device.activeVideoMinFrameDuration = duration;
            device.activeVideoMaxFrameDuration = duration;
        }];
        
        return [AVCaptureDeviceInput deviceInputWithDevice:device error:NULL];
    }
    
    void CameraSource::setupCaptureOutput() {
        AVCaptureSession *session = captureSession();
        AVCaptureVideoDataOutput *output = [[[AVCaptureVideoDataOutput alloc] init] autorelease];
        output.videoSettings = @{(NSString*)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA) };
        output.alwaysDiscardsLateVideoFrames = YES;
        
        AVCaptureConnection *connection = [output connectionWithMediaType:AVMediaTypeVideo];
        CMTime duration = frameDuration();
        if ([connection isVideoMinFrameDurationSupported]) {
            connection.videoMinFrameDuration = duration;
        }
        
        if ([connection isVideoMaxFrameDurationSupported]) {
            connection.videoMaxFrameDuration = duration;
        }
        
        if ([session canAddOutput:output]) {
            [session addOutput:output];
        }
        
        setCaptureOutput(output);
        
        sbCallback *delegate = [[[sbCallback alloc] init] autorelease];
        
        setCaptureOutputDelegate(delegate);
    }
    
    NSString *CameraSource::mediaType() {
        return AVMediaTypeVideo;
    }

    AVCaptureDevice *CameraSource::cameraWithPosition(int position) {
        for (AVCaptureDevice *device in getCaptureDevices()) {
            if (device.position == position) {
                return device;
            }
        }
        
        return nil;
    }
    
    AVCaptureDeviceInput *CameraSource::captureInputForCameraPosition(int position) {
        for (AVCaptureDeviceInput *input in inputs()) {
            if (input.device.position == position) {
                return input;
            }
        }
        
        return nil;
    }
    
    bool CameraSource::isConnectionForCurrentInput(AVCaptureConnection *connection) {
        AVCaptureInput *input = captureInput();
        for (AVCaptureInputPort *inputPort in input.ports) {
            for (AVCaptureInputPort *connectionPort in connection.inputPorts) {
                if ([connectionPort isEqual:inputPort]) {
                    return true;
                }
            }
        }
        
        return false;
    }
    
    AVCaptureDevice *CameraSource::captureDevice() {
        AVCaptureDeviceInput *input = captureInput();
        
        return input.device;
    }
    
    bool CameraSource::orientationLocked() {
        return m_orientationLocked;
    }
    
    void CameraSource::setOrientationLocked(bool orientationLocked) {
        if (orientationLocked != m_orientationLocked) {
            m_orientationLocked = orientationLocked;
            if (orientationLocked) {
                stopListeningToOrientationChange();
            } else {
                startListeningToOrientationChange();
            }
        }
    }
    
    bool CameraSource::setTorch(bool torchOn) {
        __block bool result = false;
        
        [captureSession() configureWithBlock:^(AVCaptureSession *session) {
            AVCaptureDevice *device = captureDevice();
            if (device.torchAvailable) {
                bool success = [device configureWithBlock:^(AVCaptureDevice *device) {
                    device.torchMode = torchOn ? AVCaptureTorchModeOn : AVCaptureTorchModeOff;
                }];
                
                result = success && torchOn;
            }
        }];
        
        m_torchOn = result;
        
        return result;
    }
    
    void CameraSource::toggleCamera() {
        [captureSession() configureWithBlock:^(AVCaptureSession *session) {
            removeCaptureInput(captureInput());
            
            m_isFront = !m_isFront;
            id input = captureInputForCameraPosition(captureDevicePosition());
            addCaptureInput(input);
           
            setCaptureInput(input);
            if (m_torchOn) {
                setTorch(m_torchOn);
            }
            
            reorientCamera();
            [writer() flipCamera];
        }];
    }
    
    void CameraSource::removeSessionConnections() {
        for (id input in inputs()) {
            removeCaptureInput(input);
        }
        
        setCaptureInput(nil);
        
        CaptureSessionSource::removeSessionConnections();
    }
    
    NSArray *CameraSource::inputs() {
        return m_inputs;
    }
    
    void CameraSource::setInputs(NSArray *inputs) {
        setValueForField(&m_inputs, inputs);
    }
    
    void CameraSource::reorientCamera() {
        auto orientation = m_useInterfaceOrientation ? [[UIApplication sharedApplication] statusBarOrientation] : [[UIDevice currentDevice] orientation];
        
        // use interface orientation as fallback if device orientation is facedown, faceup or unknown
        if (orientation == UIDeviceOrientationFaceDown
            || orientation == UIDeviceOrientationFaceUp
            || orientation == UIDeviceOrientationUnknown)
        {
            orientation = [[UIApplication sharedApplication] statusBarOrientation];
        }
        
        AVCaptureVideoOrientation videoOrientation = videoOrientationForInterfaceOrientation(orientation);
        
        [captureSession() configureWithBlock:^(AVCaptureSession *session) {
            for (AVCaptureVideoDataOutput *output in session.outputs) {
                for (AVCaptureConnection *connection in output.connections) {
                    if (connection.supportsVideoOrientation) {
                        connection.videoOrientation = videoOrientation;
                    }
                }
            }
        }];

        if (m_torchOn) {
            setTorch(m_torchOn);
        }
    }
    
    AVCaptureVideoOrientation CameraSource::videoOrientationForInterfaceOrientation(long orientation) {
        switch (orientation) {
                // UIInterfaceOrientationPortraitUpsideDown, UIDeviceOrientationPortraitUpsideDown
            case UIInterfaceOrientationPortraitUpsideDown:
                return AVCaptureVideoOrientationPortraitUpsideDown;
                
                // UIInterfaceOrientationLandscapeRight, UIDeviceOrientationLandscapeLeft
            case UIInterfaceOrientationLandscapeRight:
                return AVCaptureVideoOrientationLandscapeRight;
                
                // UIInterfaceOrientationLandscapeLeft, UIDeviceOrientationLandscapeRight
            case UIInterfaceOrientationLandscapeLeft:
                return AVCaptureVideoOrientationLandscapeLeft;
                
                // UIInterfaceOrientationPortrait, UIDeviceOrientationPortrait
            case UIInterfaceOrientationPortrait:
                return AVCaptureVideoOrientationPortrait;
                
            default:
                return AVCaptureVideoOrientationPortrait;
        }
    }

    void CameraSource::bufferCaptured(CMSampleBufferRef sampleBuffer) {
        [writer() encodeVideoBuffer:sampleBuffer];
        
        auto output = m_output.lock();
        if (output) {
            
            VideoBufferMetadata md(1.f / float(m_fps));
            
            md.setData(1, m_matrix, false, shared_from_this());
            
            auto pixelBuffer = std::make_shared<Apple::PixelBuffer>(CMSampleBufferGetImageBuffer(sampleBuffer) , true);
            
            pixelBuffer->setState(kVCPixelBufferStateEnqueued);
            output->pushBuffer((uint8_t*)&pixelBuffer, sizeof(pixelBuffer), md);
        }
    }
    
    bool CameraSource::setContinuousAutofocus(bool wantsContinuous) {
        AVCaptureDevice *device = captureDevice();
        AVCaptureFocusMode newMode = wantsContinuous ?  AVCaptureFocusModeContinuousAutoFocus : AVCaptureFocusModeAutoFocus;
        bool result = [device isFocusModeSupported:newMode];
        if (result) {
            result = [device configureWithBlock:^(AVCaptureDevice *device) {
                device.focusMode = newMode;
            }];
        }
        
        return result;
    }

    bool CameraSource::setContinuousExposure(bool wantsContinuous) {
        AVCaptureDevice *device = captureDevice();
        AVCaptureExposureMode newMode = wantsContinuous ? AVCaptureExposureModeContinuousAutoExposure : AVCaptureExposureModeAutoExpose;
        bool result = [device isExposureModeSupported:newMode];
        if (result) {
            result = [device configureWithBlock:^(AVCaptureDevice *device) {
                device.exposureMode = newMode;
            }];
        }

        return result;
    }
    
    bool CameraSource::setFocusPointOfInterest(float x, float y) {
        AVCaptureDevice *device = captureDevice();
        bool result = device.focusPointOfInterestSupported;
        if (result) {
            result = [device configureWithBlock:^(AVCaptureDevice *device) {
                device.focusPointOfInterest = CGPointMake(x, y);
                if (device.focusMode == AVCaptureFocusModeLocked) {
                    device.focusMode = AVCaptureFocusModeAutoFocus;
                }
                
                device.focusMode = device.focusMode;
            }];
        }
        
        return result;
    }
    
    bool CameraSource::setExposurePointOfInterest(float x, float y) {
        AVCaptureDevice *device = captureDevice();
        bool result = device.focusPointOfInterestSupported;
        if (result) {
            result = [device configureWithBlock:^(AVCaptureDevice *device) {
                device.exposurePointOfInterest = CGPointMake(x, y);
                device.exposureMode = device.exposureMode;
            }];
        }
        
        return result;
    }
    
    void CameraSource::setCaptureOutputDelegate(id value) {
        if (value != m_captureOutputDelegate) {
            [m_captureOutputDelegate setSource:std::weak_ptr<CameraSource>()];
            stopListeningToOrientationChange();
            
            CaptureSessionSource::setCaptureOutputDelegate(value);
            
            [value setSource:std::static_pointer_cast<CameraSource>(shared_from_this())];
            startListeningToOrientationChange();
            
            [captureOutput() setSampleBufferDelegate:value queue:sharedDispatchQueue()];
        }
    }
    
    void CameraSource::startListeningToOrientationChange() {
        if (m_orientationLocked) {
            return;
        }

        bool useInterfaceOrientation = m_useInterfaceOrientation;
        NSString *notificationName = useInterfaceOrientation
            ? UIApplicationDidChangeStatusBarOrientationNotification
            : UIDeviceOrientationDidChangeNotification;
        
        if (!useInterfaceOrientation) {
            [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
        }
        
        id delegate = captureOutputDelegate();
        if (delegate) {
            [[NSNotificationCenter defaultCenter] addObserver:delegate
                                                     selector:@selector(orientationChanged:)
                                                         name:notificationName
                                                       object:nil];
        }
    }
    
    void CameraSource::stopListeningToOrientationChange() {
        if (!m_orientationLocked) {
            return;
        }
        
        bool useInterfaceOrientation = m_useInterfaceOrientation;
        NSString *notificationName = useInterfaceOrientation
            ? UIApplicationDidChangeStatusBarOrientationNotification
            : UIDeviceOrientationDidChangeNotification;
        
        if (!useInterfaceOrientation) {
            [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
        }
        
        id delegate = captureOutputDelegate();
        if (delegate) {
            [[NSNotificationCenter defaultCenter] removeObserver:delegate name:notificationName object:nil];
        }
    }
    
    AVCaptureDevicePosition CameraSource::captureDevicePosition() {
        return m_isFront ? AVCaptureDevicePositionFront : AVCaptureDevicePositionBack;
    }
    
    CMTime CameraSource::frameDuration() {
        return CMTimeMake(1, m_fps);
    }
    
}
}
