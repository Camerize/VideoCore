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
#ifndef __videocore__RTMSession__
#define __videocore__RTMSession__

#include <iostream>
#include <videocore/stream/IStreamSession.hpp>
#include <videocore/stream/TCPThroughputAdaptation.h>

#include <UriParser/UriParser.hpp>

#include <functional>
#include <deque>
#include <queue>
#include <map>
#include <chrono>

#include <videocore/system/JobQueue.hpp>
#include <cstdlib>

#include <videocore/rtmp/RTMPTypes.h>
#include <videocore/system/Buffer.hpp>
#include <videocore/transforms/IOutputSession.hpp>

namespace videocore
{
    class RTMPSession;
    
    using BufStruct = struct { std::shared_ptr<Buffer> buf; std::chrono::steady_clock::time_point time; };
    
    
    enum {
        kRTMPSessionParameterWidth=0,
        kRTMPSessionParameterHeight,
        kRTMPSessionParameterFrameDuration,
        kRTMPSessionParameterVideoBitrate,
        kRTMPSessionParameterAudioFrequency,
        kRTMPSessionParameterStereo
    };
    typedef MetaData<'rtmp', int32_t, int32_t, double, int32_t, double, bool> RTMPSessionParameters_t;
    enum {
        kRTMPMetadataTimestamp=0,
        kRTMPMetadataMsgLength,
        kRTMPMetadataMsgTypeId,
        kRTMPMetadataMsgStreamId,
        kRTMPMetadataIsKeyframe
    };
    
    typedef MetaData<'rtmp', int32_t, int32_t, uint8_t, int32_t, bool> RTMPMetadata_t;
    
    using RTMPSessionStateCallback = std::function<void(RTMPSession& session, ClientState_t state)>;
    
    class RTMPSession : public IOutputSession
    {
    public:
        RTMPSession(std::string uri, RTMPSessionStateCallback callback);
        ~RTMPSession();
        
    public:
        
        // Requires RTMPMetadata_t
        void pushBuffer(const uint8_t* const data, size_t size, IMetadata& metadata);
        
        void setSessionParameters(IMetadata& parameters);
        void setBandwidthCallback(BandwidthCallback callback);
        
    private:
        
        // Deprecate sendPacket
        void sendPacket(uint8_t* data, size_t size, RTMPChunk_0 metadata);
        
        
        
        void streamStatusChanged(StreamStatus_t status);
        void write(uint8_t* data, size_t size, std::chrono::steady_clock::time_point packetTime = std::chrono::steady_clock::now(), bool isKeyframe = false);
        void dataReceived();
        void setClientState(ClientState_t state);
        void handshake();
        void handshake0();
        void handshake1();
        void handshake2();
        
        void sendConnectPacket();
        void sendReleaseStream();
        void sendFCPublish();
        void sendCreateStream();
        void sendPublish();
        void sendHeaderPacket();
        void sendSetChunkSize(int32_t chunkSize);
        void sendPong();
        void sendDeleteStream();
        void sendSetBufferTime(int milliseconds);
        
        void increaseBuffer(int64_t size);
        
        bool parseCurrentData();
        
        void handleInvoke(const uint8_t* p);
        std::string parseStatusCode(const uint8_t *p);
        int32_t amfPrimitiveObjectSize(const uint8_t* p);
        
    private:
        
        int parseSingleBS(const std::vector<uint8_t>& buf, size_t len);
        int parseSingleMessage(int msg_type_id, int msg_size, const std::vector<uint8_t>& buf, int next);
        int parseSingleChunk(int chunk_stream_id, int msg_type_id, int msg_size, const std::vector<uint8_t>& buf, size_t len, int next);
        
        JobQueue            m_networkQueue;
        JobQueue            m_jobQueue;
        std::chrono::steady_clock::time_point m_sentKeyframe;
        std::condition_variable m_networkCond;
        std::mutex              m_networkMutex;
        
        RingBuffer          m_streamOutRemainder;
        Buffer              m_s1, m_c1;
        
        TCPThroughputAdaptation m_throughputSession;
        
        uint64_t            m_previousTs;
        
        std::deque<BufStruct> m_streamOutQueue;
        
        std::map<int, uint64_t>             m_previousChunkData;
        
        //this is real hacky, should make a struct
        std::map<int, std::vector<uint8_t>> m_previousInChunkData;
        std::map<int, std::size_t>          m_previousInChunkLen;
        std::map<int, std::size_t>          m_previousInChunkTypeId;
        
        std::vector<uint8_t>                m_recvBuffer;
        
        std::unique_ptr<RingBuffer>         m_streamInBuffer;
        std::unique_ptr<IStreamSession>     m_streamSession;
        std::vector<uint8_t> m_outBuffer;
        http::url                       m_uri;
        
        RTMPSessionStateCallback        m_callback;
        BandwidthCallback               m_bandwidthCallback;
        
        std::string                     m_playPath;
        std::string                     m_app;
        std::map<int32_t, std::string>  m_trackedCommands;
        
        size_t          m_outChunkSize;
        size_t          m_inChunkSize;
        int64_t         m_bufferSize;
        
        int32_t         m_streamId;
        int32_t         m_createStreamInvoke;
        int32_t         m_numberOfInvokes;
        int32_t         m_frameWidth;
        int32_t         m_frameHeight;
        int32_t         m_bitrate;
        double          m_frameDuration;
        double          m_audioSampleRate;
        bool            m_audioStereo;
        
        ClientState_t  m_state;
      
        bool            m_clearing;
        bool            m_ending;
    };
}

#endif /* defined(__videocore__RTMSession__) */
