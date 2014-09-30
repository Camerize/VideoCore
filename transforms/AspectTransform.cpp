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

#include <videocore/transforms/AspectTransform.h>
#include <videocore/mixers/IVideoMixer.hpp>

#include <glm/gtc/matrix_transform.hpp>

#include <CoreVideo/CoreVideo.h>

namespace videocore {
    
    AspectTransform::AspectTransform(int boundingWidth,
                                     int boundingHeight,
                                     AspectMode aspectMode)
    : m_boundingWidth(boundingWidth),
    m_boundingHeight(boundingHeight),
    m_aspectMode(aspectMode),
    m_boundingBoxDirty(true),
    m_prevWidth(0),
    m_prevHeight(0)
    {
    }
    
    AspectTransform::~AspectTransform()
    {
    }
    
    void
    AspectTransform::setOutput(std::shared_ptr<IOutput> output)
    {
        m_output = output;
    }
    
    void
    AspectTransform::setBoundingSize(int boundingWidth,
                                     int boundingHeight)
    {
        m_boundingWidth = boundingWidth;
        m_boundingHeight = boundingHeight;
        m_boundingBoxDirty = true;
    }
    
    void
    AspectTransform::setAspectMode(videocore::AspectTransform::AspectMode aspectMode)
    {
        m_boundingBoxDirty = true;
        m_aspectMode = aspectMode;
    }
    
    void
    AspectTransform::setBoundingBoxDirty()
    {
        m_boundingBoxDirty = true;
    }
    
    void
    AspectTransform::pushBuffer(const uint8_t *const data,
                                size_t size,
                                videocore::IMetadata &metadata)
    {
        auto output = m_output.lock();
        
        if(output) {
            CVPixelBufferRef pb = (CVPixelBufferRef)data;
            CVPixelBufferLockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
            
            float width = CVPixelBufferGetWidth(pb);
            float height = CVPixelBufferGetHeight(pb);
            
            if(width != m_prevWidth || height != m_prevHeight) {
                setBoundingBoxDirty();
                m_prevHeight = height;
                m_prevWidth = width;
            }
            
            if(m_boundingBoxDirty) {
                // TODO: Replace CVPixelBufferRef with an internal format.
                
                float wfac = float(m_boundingWidth) / width;
                float hfac = float(m_boundingHeight) / height;
                
                const float mult = (m_aspectMode == kAspectFit ? (wfac < hfac) : (wfac > hfac)) ? wfac : hfac;
                
                wfac = width*mult / float(m_boundingWidth);
                hfac = height*mult / float(m_boundingHeight);
                
                m_scale = glm::vec3(wfac,hfac,1.f);
                
                m_boundingBoxDirty = false;
            }
            
            CVPixelBufferUnlockBaseAddress(pb, kCVPixelBufferLock_ReadOnly);
            
            
            
            videocore::VideoBufferMetadata* mdp = dynamic_cast<videocore::VideoBufferMetadata*>(&metadata);
            videocore::VideoBufferMetadata md(metadata.timestampDelta);
            
            
            if (mdp != NULL)
                md = *mdp;
            else
             {
                float w = float(CVPixelBufferGetWidth(pb));
                float h = float(CVPixelBufferGetHeight(pb));
                
                const float wfac = 1;
                const float hfac = 1;
                
                const float mult = (m_aspectMode == kAspectFit ? (wfac < hfac) : (wfac > hfac)) ? wfac : hfac;
                
                w *= mult;
                h *= mult;
                
                glm::mat4 mat(1.f);
                 
                mat = glm::translate(mat,
                                     glm::vec3(1 * 2.f - 1.f,   // The compositor uses normalized device co-ordinates.
                                               1 * 2.f - 1.f,   // i.e. [ -1 .. 1 ]
                                               0.f));
                
                mat = glm::scale(mat,
                                 glm::vec3(1, //
                                           1, // size is a percentage for scaling.
                                           1.f));
                 
                 md.setData(1, mat, std::weak_ptr<ISource>());
                 

            }
            
            glm::mat4& mat = md.getData<videocore::kVideoMetadataMatrix>();
            mat = glm::scale(mat, m_scale);
            
            output->pushBuffer(data, size, md);
        }
    }
    
}