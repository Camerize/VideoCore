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
#import <AVFoundation/AVFoundation.h>

#include <videocore/transforms/Apple/MP4Multiplexer.h>
#include <videocore/mixers/IAudioMixer.hpp>

dispatch_queue_t _graphManagementQueue = dispatch_queue_create("com.videocore.session.mov", DISPATCH_QUEUE_SERIAL);

double video_pts = 0;
double audio_pts = 0;
namespace videocore { namespace Apple {
 
    
    MP4Multiplexer::MP4Multiplexer() : m_assetWriter(nullptr), m_videoInput(nullptr), m_audioInput(nullptr), m_videoFormat(nullptr), m_audioFormat(nullptr), m_fps(30), m_framecount(0)
    {

        
    }
    MP4Multiplexer::~MP4Multiplexer()
    {
        if(m_assetWriter) {
            NSLog(@"Closing asset writer");
            __block AVAssetWriter* writer = (AVAssetWriter*)m_assetWriter;
            [writer finishWritingWithCompletionHandler:^{
                NSLog(@"Closed asset writer");
                [writer release];
            }];
            
        }
        if(m_videoFormat) {
            CFRelease(m_videoFormat);
        }
    }
    
    void MP4Multiplexer::setBandwidthCallback(BandwidthCallback callback) {}

    void
    MP4Multiplexer::setSessionParameters(videocore::IMetadata &parameters)
    {
        auto & parms = dynamic_cast<videocore::Apple::MP4SessionParameters_t&>(parameters);
        
        auto filename = parms.getData<kMP4SessionFilename>()  ;
        m_fps = parms.getData<kMP4SessionFPS>();
        m_width = parms.getData<kMP4SessionWidth>();
        m_height = parms.getData<kMP4SessionHeight>();
        NSLog(@"(%d, %d, %d)", m_fps, m_width, m_height);
        m_filename = filename;
        
        CMFormatDescriptionRef audioDesc, videoDesc ;

        CMFormatDescriptionCreate(kCFAllocatorDefault, kCMMediaType_Audio, 'aac ', NULL, &audioDesc);
        CMFormatDescriptionCreate(kCFAllocatorDefault, kCMMediaType_Video, 'avc1', NULL, &videoDesc);
        
        AVAssetWriterInput* video = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeVideo outputSettings:nil sourceFormatHint:nil];
        AVAssetWriterInput* audio = [AVAssetWriterInput assetWriterInputWithMediaType:AVMediaTypeAudio outputSettings:nil sourceFormatHint:nil];
        
        NSURL* fileUrl = [NSURL fileURLWithPath:[NSString stringWithUTF8String:filename.c_str()]];
        AVAssetWriter* writer = [[AVAssetWriter alloc] initWithURL:fileUrl fileType:AVFileTypeQuickTimeMovie error:nil];
        video.expectsMediaDataInRealTime = YES;
        audio.expectsMediaDataInRealTime = YES;
        
        [writer addInput:video];
        [writer addInput:audio];
        
        CMTime time = {0};
        time.timescale = m_fps;
        time.flags = kCMTimeFlags_Valid;
        
        [writer startWriting];
        [writer startSessionAtSourceTime:time];
        
        m_assetWriter = writer;
        m_audioInput = audio;
        m_videoInput = video;
    }
    void
    MP4Multiplexer::pushBuffer(const uint8_t *const data, size_t size, videocore::IMetadata &metadata)
    {
        switch(metadata.type()) {
            case 'vide':
                dispatch_sync(_graphManagementQueue, ^{
                    // Process video
                    pushVideoBuffer(data,size,metadata);
                });
                break;
                
            case 'soun':
                dispatch_sync(_graphManagementQueue, ^{
                    // Process audio
                    pushAudioBuffer(data,size,metadata);
                });
                
                break;
            default:
                break;
        }
    }
    
    void
    MP4Multiplexer::pushVideoBuffer(const uint8_t* const data, size_t size, IMetadata& metadata)
    {
        const int nalu_type = data[4] & 0x1F;
        
        if( nalu_type == 7 && m_sps.empty() ) {
            m_sps.insert(m_sps.end(), &data[4], &data[size-1]);
            if(!m_pps.empty()) {
                createAVCC();
            }
        }
        else if( nalu_type == 8 && m_pps.empty() ) {
            m_pps.insert(m_pps.end(), &data[4], &data[size-1]);
            if(!m_sps.empty()) {
                createAVCC();
            }
        }
        else if (nalu_type <= 5)
        {
            CMSampleBufferRef sample;
            CMBlockBufferRef buffer;
            CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, (void*)data, size, kCFAllocatorDefault, NULL, 0, size, kCMBlockBufferAssureMemoryNowFlag, &buffer);
            
            double delta=1/30.0*1000;
            CMSampleTimingInfo videoSampleTimingInformation =  {CMTimeMake(delta, 1000.), CMTimeMake(video_pts, 1000.) , kCMTimeInvalid};
            
            video_pts += delta;

            CMSampleBufferCreate(kCFAllocatorDefault, buffer, true, NULL, NULL, (CMFormatDescriptionRef)m_videoFormat, 1, 1, &videoSampleTimingInformation, 1, &size, &sample);
            CMSampleBufferMakeDataReady(sample);
            
            AVAssetWriterInput* video = (AVAssetWriterInput*)m_videoInput;
            
            //NSLog(@"Appending video");
            if(video.readyForMoreMediaData) {
                BOOL rv=[video appendSampleBuffer:sample];
                auto v = (AVAssetWriter*)m_assetWriter;
                
                if (!rv)
                    NSLog(@"Failed video %d, %d, %@", rv, (int)v.status, v.error);
                /*else
                    NSLog(@"DID WRITE VIDEO");
                */
            } else {
                NSLog(@"Dropped Video Frame");
            }
            
            CFRelease(sample);
            //CFRelease(buffer);
            
        }
        
    }
    void
    MP4Multiplexer::pushAudioBuffer(const uint8_t *const data, size_t size, videocore::IMetadata &metadata)
    {
        if(!m_audioFormat)
        {
            //first = true;
            AudioBufferMetadata& md = dynamic_cast<AudioBufferMetadata&>(metadata);
            
            
            AudioStreamBasicDescription asbd = {0};
            asbd.mFormatID = kAudioFormatMPEG4AAC;
            asbd.mFormatFlags = 0;
            asbd.mFramesPerPacket = 1024;
            asbd.mSampleRate = md.getData<kAudioMetadataFrequencyInHz>();
            asbd.mChannelsPerFrame = md.getData<kAudioMetadataChannelCount>();
            
            CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, nullptr, size, data, NULL, (CMAudioFormatDescriptionRef*)&m_audioFormat);
            
        } else {
            
            CMSampleBufferRef sample;
            CMBlockBufferRef buffer;
            CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, (void*)data, size, kCFAllocatorDefault, NULL, 0, size, kCMBlockBufferAssureMemoryNowFlag, &buffer);
            
            double delta=1024/44100.0*1000;
            CMSampleTimingInfo audioSampleTimingInformation =  {CMTimeMake(delta, 1000.), CMTimeMake(audio_pts, 1000.) , kCMTimeInvalid};

            audio_pts += delta;

            CMSampleBufferCreate(kCFAllocatorDefault,
                                 buffer,
                                 true,
                                 NULL,
                                 NULL,
                                 (CMFormatDescriptionRef)m_audioFormat,
                                 1,
                                 1,
                                 &audioSampleTimingInformation,
                                 1,
                                 &size,
                                 &sample);
            CMSampleBufferMakeDataReady(sample);
            
            CFDictionaryRef dict = NULL;
  
            //static bool first = true;
            if (true){
            //    first = false;
                
                dict = CMTimeCopyAsDictionary(CMTimeMake(1024*2, 44100), kCFAllocatorDefault);
                
                CMSetAttachment(sample, kCMSampleBufferAttachmentKey_TrimDurationAtStart, dict, kCMAttachmentMode_ShouldNotPropagate);
            }

            AVAssetWriterInput* audio = (AVAssetWriterInput*)m_audioInput;
                
            if (audio.readyForMoreMediaData){
                //NSLog(@"Appending audio");
                BOOL rv = [audio appendSampleBuffer:sample];
                auto v = (AVAssetWriter*)m_assetWriter;
                if (!rv)
                    NSLog(@"Failed Audio %d, %d, %@", rv, (int)v.status, v.error);
                /*else
                    NSLog(@"DID WRITE Audio %f,%f", audio_pts, video_pts);
                */
            } else {
                NSLog(@"Dropped Audio Frame");
            }
           
            
            CFRelease(sample);
            if (dict) CFRelease(dict);
            //CFRelease(buffer);
        }
    }
    void
    MP4Multiplexer::createAVCC()
    {
        std::vector<uint8_t> avcc;
        
        avcc.push_back(0x01);
        avcc.push_back(m_sps[1]);
        avcc.push_back(m_sps[2]);
        avcc.push_back(m_sps[3]);
        avcc.push_back(0xFC|0x3);
        avcc.push_back(0xE0|0x1);
        
        /*
        const short sps_size = __builtin_bswap16(m_sps.size());
        const short pps_size = __builtin_bswap16(m_pps.size());
        */
        //avcc.insert(avcc.end(), &sps_size, &sps_size+1);
        avcc.push_back(m_sps.size()>>8);
        avcc.push_back(m_sps.size()%256);
        
        avcc.insert(avcc.end(), m_sps.begin(), m_sps.end());
        
        avcc.push_back(0x01);
        avcc.push_back(m_pps.size()>>8);
        avcc.push_back(m_pps.size()%256);
        
       // avcc.insert(avcc.end(), &pps_size, &pps_size+1);
        avcc.insert(avcc.end(), m_pps.begin(), m_pps.end());
        
        const char *avcC = "avcC";
        const CFStringRef avcCKey = CFStringCreateWithCString(kCFAllocatorDefault, avcC, kCFStringEncodingUTF8);
        const CFDataRef avcCValue = CFDataCreate(kCFAllocatorDefault, &avcc[0], avcc.size());
        const void *atomDictKeys[] = { avcCKey };
        const void *atomDictValues[] = { avcCValue };
        CFDictionaryRef atomsDict = CFDictionaryCreate(kCFAllocatorDefault, atomDictKeys, atomDictValues, 1, nil, nil);
        
        const void *extensionDictKeys[] = { kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms };
        const void *extensionDictValues[] = { atomsDict };
        CFDictionaryRef extensionDict = CFDictionaryCreate(kCFAllocatorDefault, extensionDictKeys, extensionDictValues, 1, nil, nil);
     
        CMVideoFormatDescriptionCreate(kCFAllocatorDefault, kCMVideoCodecType_H264, m_width, m_height, extensionDict, (CMVideoFormatDescriptionRef*)&m_videoFormat);
        CFRelease(extensionDict);
        CFRelease(atomsDict);
        
    }
    
}
}