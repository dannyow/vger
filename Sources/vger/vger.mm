//  Copyright © 2021 Audulus LLC. All rights reserved.

#import "vger.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

#if TARGET_OS_OSX
#import <Cocoa/Cocoa.h>
#else
#import <UIKit/UIKit.h>
#endif

#import "vgerRenderer.h"
#import "vgerTextureManager.h"
#import "vgerGlyphCache.h"
#import "vgerTileRenderer.h"

using namespace simd;
#import "sdf.h"
#import "bezier.h"
#import "vger_private.h"

vger::vger(uint32_t flags) {
    device = MTLCreateSystemDefaultDevice();
    renderer = [[vgerRenderer alloc] initWithDevice:device pixelFormat:MTLPixelFormatBGRA8Unorm];
    glowRenderer = [[vgerRenderer alloc] initWithDevice:device pixelFormat:MTLPixelFormatRGBA16Unorm];
    glyphCache = [[vgerGlyphCache alloc] initWithDevice:device];
    printf("prim buffer size: %d MB\n", (int)(maxPrims * sizeof(vgerPrim))/(1024*1024));
    printf("cv buffer size: %d MB\n", (int)(maxCvs * sizeof(float2))/(1024*1024));
    printf("xform buffer size: %d MB\n", (int)(maxPrims * sizeof(simd_float3x3))/(1024*1024));
    printf("paints buffer size: %d MB\n", (int)(maxPrims * sizeof(vgerPaint))/(1024*1024));

    if(flags & VGER_DOUBLE_BUFFER) {
        maxBuffers = 2;
    } else if(flags & VGER_TRIPLE_BUFFER) {
        maxBuffers = 3;
    }

    for(int i=0;i<maxBuffers;++i) {

        vgerScene scene;
        for(int layer=0;layer<VGER_MAX_LAYERS;++layer) {
            auto prims = [device newBufferWithLength:maxPrims * sizeof(vgerPrim)
                                           options:MTLResourceStorageModeShared];

            assert(prims);
            prims.label = @"prim buffer";
            scene.prims[layer] = prims;
        }


        scene.cvs = [device newBufferWithLength:maxCvs * sizeof(float2)
                                       options:MTLResourceStorageModeShared];
        assert(scene.cvs);
        scene.cvs.label = @"cv buffer";

        scene.xforms = [device newBufferWithLength:maxPrims * sizeof(simd_float3x3) options:MTLResourceStorageModeShared];
        assert(scene.xforms);
        scene.xforms.label = @"xform buffer";

        scene.paints = [device newBufferWithLength:maxPrims * sizeof(vgerPaint) options:MTLResourceStorageModeShared];
        assert(scene.paints);
        scene.paints.label = @"paints buffer";

        scenes[i] = scene;
    }
    txStack.push_back(matrix_identity_float3x3);

    auto desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:1 height:1 mipmapped:NO];
    nullTexture = [device newTextureWithDescriptor:desc];

    textures = [NSMutableArray new];
    // Texture 0 is used to indicate errors.
    [textures addObject:nullTexture];

    textureLoader = [[MTKTextureLoader alloc] initWithDevice:device];
}

vgerContext vgerNew(uint32_t flags) {
    return new vger(flags);
}

void vgerDelete(vgerContext vg) {
    delete vg;
}

void vger::begin(float windowWidth, float windowHeight, float devicePxRatio) {
    currentScene = (currentScene+1) % maxBuffers;
    auto& scene = scenes[currentScene];
    for(int layer=0;layer<VGER_MAX_LAYERS;++layer) {
        primPtr[layer] = (vgerPrim*) scene.prims[layer].contents;
        primCount[layer] = 0;
    }
    currentLayer = 0;
    cvPtr = (float2*) scene.cvs.contents;
    cvCount = 0;
    xformPtr = (float3x3*) scene.xforms.contents;
    xformCount = 0;
    paintPtr = (vgerPaint*) scene.paints.contents;
    paintCount = 0;
    windowSize = {windowWidth, windowHeight};
    this->devicePxRatio = devicePxRatio;
    computedGlyphBounds = false;

    // Prune the text cache.
    for(auto it = std::begin(textCache); it != std::end(textCache);) {
        if (it->second.lastFrame != currentFrame) {
            it = textCache.erase(it);
        } else {
            ++it;
        }
    }

    currentFrame++;

    // Do we need to create a new glyph cache?
    if(glyphCache.usage > 0.8f) {
        glyphCache = [[vgerGlyphCache alloc] initWithDevice:device];
        textCache.clear();
    }
}

void vgerBegin(vgerContext vg, float windowWidth, float windowHeight, float devicePxRatio) {

    vg->begin(windowWidth, windowHeight, devicePxRatio);

    // Add a dummy prim so we always render something (and at least the
    // framebuffer is cleared).
    vgerFillRect(vg, float2{0,0}, float2{0,0}, 0, vgerColorPaint(vg, float4{0,0,0,0}));
}

vgerImageIndex vgerCreateImage(vgerContext vg, const char* filename) {

    auto url = [NSURL fileURLWithPath:[NSString stringWithUTF8String:filename]];

    NSError* error;
    auto tex = [vg->textureLoader newTextureWithContentsOfURL:url options:nil error:&error];

    if(error) {
        NSLog(@"error loading texture: %@", error);
        return {0};
    }

    return vgerAddMTLTexture(vg, tex);
}

vgerImageIndex vgerCreateImageMem(vgerContext vg, const uint8_t* data, size_t size) {

    assert(data);

    if(size == 0) {
        NSLog(@"Error: image data is empty");
        return {0};
    }

    auto nsdata = [NSData dataWithBytesNoCopy:(void*)data length:size freeWhenDone:NO];

    NSError* error;
    auto tex = [vg->textureLoader newTextureWithData:nsdata options:nil error:&error];

    if(error) {
        NSLog(@"error loading texture: %@", error);
        return {0};
    }

    return vgerAddMTLTexture(vg, tex);
}

vgerImageIndex vgerAddTexture(vgerContext vg, const uint8_t* data, int width, int height) {
    assert(data);

    auto desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:width height:height mipmapped:NO];
    desc.usage = MTLTextureUsageShaderRead;
#if TARGET_OS_OSX || TARGET_OS_MACCATALYST
    desc.storageMode = MTLStorageModeManaged;
#else
    desc.storageMode = MTLStorageModeShared;
#endif
    auto tex = [vg->device newTextureWithDescriptor:desc];
    assert(tex);
    tex.label = @"user texture";

    [tex replaceRegion:MTLRegionMake2D(0, 0, width, height) mipmapLevel:0 withBytes:data bytesPerRow:width*sizeof(uint32_t)];

    return vgerAddMTLTexture(vg, tex);
}

vgerImageIndex vgerAddMTLTexture(vgerContext vg, id<MTLTexture> tex) {
    assert(tex);
    [vg->textures addObject:tex];
    return {uint32_t(vg->textures.count)-1};
}

void vgerDeleteTexture(vgerContext vg, vgerImageIndex texID) {
    assert(vg);
    [vg->textures setObject:vg->nullTexture atIndexedSubscript:texID.index];
}


vector_int2 vgerTextureSize(vgerContext vg, vgerImageIndex texID) {
    assert(vg);
    assert(texID.index < vg->textures.count);
    auto tex = [vg->textures objectAtIndex:texID.index];
    return {int(tex.width), int(tex.height)};
}

void vgerRender(vgerContext vg, const vgerPrim* prim) {

    if(vg->primCount[vg->currentLayer] < vg->maxPrims) {
        auto& pp = vg->primPtr[vg->currentLayer];
        *pp = *prim;
        pp->xform = vg->addxform(vg->txStack.back());
        pp++;
        vg->primCount[vg->currentLayer]++;
    }

}

void vgerFillCircle(vgerContext vg, vector_float2 center, float radius, vgerPaintIndex paint) {

    vgerPrim prim {
        .type = vgerCircle,
        .cvs = { center },
        .radius = radius,
        .paint = paint.index,
        .width = 0.0
    };

    vgerRender(vg, &prim);
}

void vgerStrokeArc(vgerContext vg, vector_float2 center, float radius, float width, float rotation, float aperture, vgerPaintIndex paint) {

    vgerPrim prim {
        .type = vgerArc,
        .radius = radius,
        .cvs = { center, {sin(rotation), cos(rotation)}, {sin(aperture), cos(aperture)} },
        .width = width,
        .paint = paint.index
    };

    vgerRender(vg, &prim);
}

void vgerFillRect(vgerContext vg, vector_float2 min, vector_float2 max, float radius, vgerPaintIndex paint) {

    vgerPrim prim {
        .type = vgerRect,
        .radius = radius,
        .cvs = { min, max },
        .paint = paint.index
    };

    vgerRender(vg, &prim);
}

void vgerStrokeRect(vgerContext vg, vector_float2 min, vector_float2 max, float radius, float width, vgerPaintIndex paint) {

    vgerPrim prim {
        .type = vgerRectStroke,
        .radius = radius,
        .width = width,
        .cvs = { min, max },
        .paint = paint.index
    };

    vgerRender(vg, &prim);

}

void vgerStrokeBezier(vgerContext vg, vgerBezierSegment s, float width, vgerPaintIndex paint) {

    vgerPrim prim {
        .type = vgerBezier,
        .width = width,
        .cvs = { s.a, s.b, s.c },
        .paint = paint.index
    };

    vgerRender(vg, &prim);
}

void vgerStrokeSegment(vgerContext vg, vector_float2 a, vector_float2 b, float width, vgerPaintIndex paint) {

    vgerPrim prim {
        .type = vgerSegment,
        .width = width,
        .cvs = { a, b },
        .paint = paint.index
    };

    vgerRender(vg, &prim);
}

void vgerStrokeWire(vgerContext vg, vector_float2 a, vector_float2 b, float width, vgerPaintIndex paint) {

    vgerPrim prim {
        .type = vgerWire,
        .width = width,
        .cvs = { a, b },
        .paint = paint.index
    };

    vgerRender(vg, &prim);
}

static float averageScale(const float3x3& M)
{
    return 0.5f * (length(M.columns[0].xy) + length(M.columns[1].xy));
}

static float2 alignOffset(CTLineRef line, int align) {

    float2 t = {0,0};
    auto lineBounds = CTLineGetImageBounds(line, nil);

    if(align & VGER_ALIGN_RIGHT) {
        t.x = -lineBounds.size.width;
    } else if(align & VGER_ALIGN_CENTER) {
        t.x = -0.5 * lineBounds.size.width;
    }

    CGFloat ascent, descent;
    CTLineGetTypographicBounds(line, &ascent, &descent, nullptr);
    if(align & VGER_ALIGN_TOP) {
        t.y = -ascent;
    } else if(align & VGER_ALIGN_MIDDLE) {
        t.y = 0.5 * (descent - ascent);
    } else if(align & VGER_ALIGN_BOTTOM) {
        t.y = descent;
    }

    return t;
}

void vgerText(vgerContext vg, const char* str, float4 color, int align) {
    vg->renderText(str, color, align);
}

bool vger::renderCachedText(const TextLayoutKey& key, vgerPaintIndex paint, uint16_t xform) {

    // Do we already have text in the cache?
    auto iter = textCache.find(key);
    if(iter != textCache.end()) {
        // Copy prims to output.
        auto& info = iter->second;
        info.lastFrame = currentFrame;
        for(auto& prim : info.prims) {
            if(primCount[currentLayer] < maxPrims) {
                *(primPtr[currentLayer]) = prim;
                primPtr[currentLayer]->paint = paint.index;
                // Keep the old image index.
                // primPtr->paint.image = prim.paint.image;
                primPtr[currentLayer]->xform = xform;
                primPtr[currentLayer]++;
                primCount[currentLayer]++;
            }
        }
        return true;
    }

    return false;
}

void vger::renderTextLine(CTLineRef line, TextLayoutInfo& textInfo, vgerPaintIndex paint, float2 offset, float scale, uint16_t xform) {

    CFRange entire = CFRangeMake(0, 0);

    NSArray* runs = (__bridge id) CTLineGetGlyphRuns(line);
    for(id r in runs) {
        CTRunRef run = (__bridge CTRunRef)r;
        size_t glyphCount = CTRunGetGlyphCount(run);

        glyphs.resize(glyphCount);
        CTRunGetGlyphs(run, entire, glyphs.data());

        for(int i=0;i<glyphCount;++i) {

            auto info = [glyphCache getGlyph:glyphs[i] scale:scale];
            if(info.regionIndex != -1) {

                CGRect r = CTRunGetImageBounds(run, nil, CFRangeMake(i, 1));
                float2 p = {float(r.origin.x), float(r.origin.y)};
                float2 sz = {float(r.size.width), float(r.size.height)};

                float2 a = p+offset, b = a+sz;

                float w = info.glyphBounds.size.width;
                float h = info.glyphBounds.size.height;

                float originY = info.textureHeight-GLYPH_MARGIN;

                vgerPrim prim = {
                    .type = vgerGlyph,
                    .paint = paint.index,
                    .quadBounds = { a, b },
                    .texBounds = {
                        float2{GLYPH_MARGIN,   originY},
                        float2{GLYPH_MARGIN+w, originY-h}
                    },
                    .xform = xform
                };

                prim.glyph = info.regionIndex;

                textInfo.prims.push_back(prim);

                if(primCount[currentLayer] < maxPrims) {
                    auto& pp = primPtr[currentLayer];
                    *pp = prim;
                    pp++;
                    primCount[currentLayer]++;
                }
            }
        }
    }

}

void vger::renderGlyphPath(CGGlyph glyph, vgerPaintIndex paint, float2 position, uint16_t xform) {

    auto& info = glyphPathCache.getInfo(glyph);
    auto n = cvCount;
    
    vgerSave(this);
    vgerTranslate(this, position);
    
    for(auto& prim : info.prims) {
        if(primCount[currentLayer] < maxPrims) {
            auto& pp = primPtr[currentLayer];
            *pp = prim;
            pp->xform = xform;
            pp->paint = paint.index;
            pp->start += n;
            pp++;
            primCount[currentLayer]++;
        }
    }
    
    for(auto cv : info.cvs) {
        addCV(cv);
    }
    
    vgerRestore(this);
}

CTLineRef vger::createCTLine(const char* str) {

    assert(str);

    auto attributes = @{ NSFontAttributeName : (__bridge id)glyphPathCache.ctFont };
    auto string = [NSString stringWithUTF8String:str];
    assert(string);
    auto attrString = [[NSAttributedString alloc] initWithString:string attributes:attributes];
    auto typesetter = CTTypesetterCreateWithAttributedString((__bridge CFAttributedStringRef)attrString);
    auto line = CTTypesetterCreateLine(typesetter, CFRangeMake(0, attrString.length));

    CFRelease(typesetter);
    return line;

}

bool glyphPaths = false;

void vger::renderText(const char* str, float4 color, int align) {

    assert(str);

    if(str[0] == 0) {
        return;
    }
    
    auto paint = vgerColorPaint(this, color);
    auto xform = addxform(txStack.back());
    
    if(glyphPaths) {

        auto line = createCTLine(str);
        auto offset = alignOffset(line, align);

        NSArray* runs = (__bridge id) CTLineGetGlyphRuns(line);
        for(id r in runs) {
            CTRunRef run = (__bridge CTRunRef)r;
            size_t glyphCount = CTRunGetGlyphCount(run);

            glyphs.resize(glyphCount);
            CFRange entire = CFRangeMake(0, 0);
            CTRunGetGlyphs(run, entire, glyphs.data());

            for(int i=0;i<glyphCount;++i) {

                CGRect r = CTRunGetImageBounds(run, nil, CFRangeMake(i, 1));
                float2 p = float2{float(r.origin.x), float(r.origin.y)} + offset;

                renderGlyphPath(glyphs[i], paint, p, xform);
            }
        }

        CFRelease(line);
        
    } else {

        auto scale = averageScale(txStack.back()) * devicePxRatio;
        auto key = TextLayoutKey{std::string(str), scale, align};
        
        if(renderCachedText(key, paint, xform)) {
            return;
        }

        // Text cache miss, do more expensive typesetting.
        auto line = createCTLine(str);

        auto& textInfo = textCache[key];
        textInfo.lastFrame = currentFrame;

        renderTextLine(line, textInfo, paint, alignOffset(line, align), scale, xform);

        CFRelease(line);
        
    }

}

void vgerTextBounds(vgerContext vg, const char* str, float2* min, float2* max, int align) {

    assert(str);
    assert(min);
    assert(max);

    if(str[0] == 0) {
        *min = *max = float2{0,0};
        return;
    }

    auto line = vg->createCTLine(str);

    auto bounds = CTLineGetImageBounds(line, nil);
    min->x = bounds.origin.x;
    min->y = bounds.origin.y;
    max->x = bounds.origin.x + bounds.size.width;
    max->y = bounds.origin.y + bounds.size.height;

    auto offset = alignOffset(line, align);
    *min += offset;
    *max += offset;

    CFRelease(line);

}

void vgerTextBox(vgerContext vg, const char* str, float breakRowWidth, float4 color, int align) {
    vg->renderTextBox(str, breakRowWidth, color, align);
}

static constexpr float big = 10000;

CTFrameRef vger::createCTFrame(const char* str, int align, float breakRowWidth) {

    assert(str);

    auto *paragraphStyle = [[NSMutableParagraphStyle alloc] init];
    if(align & VGER_ALIGN_CENTER) {
        paragraphStyle.alignment = NSTextAlignmentCenter;
    } else if(align & VGER_ALIGN_RIGHT) {
        paragraphStyle.alignment = NSTextAlignmentRight;
    }
    auto attributes = @{ NSFontAttributeName : (__bridge id)[glyphCache getFont],
                         NSParagraphStyleAttributeName : paragraphStyle
    };
    auto string = [NSString stringWithUTF8String:str];
    auto attrString = [[NSAttributedString alloc] initWithString:string attributes:attributes];
    auto framesetter = CTFramesetterCreateWithAttributedString((__bridge CFAttributedStringRef)attrString);

    auto rectPath = CGPathCreateWithRect(CGRectMake(0, 0, breakRowWidth, big), NULL);
    auto frame = CTFramesetterCreateFrame(framesetter,
                                          CFRangeMake(0, attrString.length),
                                          rectPath,
                                          NULL);

    CFRelease(rectPath);
    CFRelease(framesetter);
    return frame;
}

void vger::renderTextBox(const char* str, float breakRowWidth, float4 color, int align) {

    assert(str);

    if(str[0] == 0) {
        return;
    }

    auto paint = vgerColorPaint(this, color);
    auto scale = averageScale(txStack.back()) * devicePxRatio;
    auto key = TextLayoutKey{std::string(str), scale, align, breakRowWidth};
    auto xform = addxform(txStack.back());

    if(renderCachedText(key, paint, xform)) {
        return;
    }

    auto frame = createCTFrame(str, align, breakRowWidth);

    NSArray *lines = (__bridge id)CTFrameGetLines(frame);

    std::vector<CGPoint> lineOrigins(lines.count);
    CTFrameGetLineOrigins(frame, CFRangeMake(0, 0), lineOrigins.data());

    auto& textInfo = textCache[key];
    textInfo.lastFrame = currentFrame;

    int lineIndex = 0;
    for(id obj in lines) {
        CTLineRef line = (__bridge CTLineRef)obj;
        auto o = lineOrigins[lineIndex++];
        renderTextLine(line, textInfo, paint, float2{float(o.x),float(o.y)-big}, scale, xform);
    }

    CFRelease(frame);
}

void vgerTextBoxBounds(vgerContext vg, const char* str, float breakRowWidth, float2* min, float2* max, int align) {

    assert(str);
    assert(min);
    assert(max);

    if(str[0] == 0) {
        *min = *max = float2{0,0};
        return;
    }

    CFRange entire = CFRangeMake(0, 0);

    auto frame = vg->createCTFrame(str, align, breakRowWidth);

    NSArray *lines = (__bridge id)CTFrameGetLines(frame);
    assert(lines);

    *min = float2{FLT_MAX, FLT_MAX};
    *max = -*min;

    CGPoint origins[lines.count];
    CTFrameGetLineOrigins(frame, CFRangeMake(0, lines.count), origins);

    int i = 0;
    for(id obj in lines) {
        auto line = (__bridge CTLineRef)obj;
        auto bounds = CTLineGetImageBounds(line, nil);

        bounds.origin.x += origins[i].x;
        bounds.origin.y += origins[i].y;

        min->x = std::min(float(bounds.origin.x), min->x);
        max->x = std::max(float(bounds.origin.x + bounds.size.width), max->x);

        min->y = std::min(float(bounds.origin.y), min->y);
        max->y = std::max(float(bounds.origin.y + bounds.size.height), max->y);

        ++i;
    }

    min->y -= big;
    max->y -= big;

    CFRelease(frame);

}

void vger::fill(vgerPaintIndex paint) {

    if(primCount[currentLayer] == maxPrims) {
        return;
    }

    if(yScanner.segments.size() == 0) {
        return;
    }

    auto xform = addxform(txStack.back());

    yScanner._init();

    while(yScanner.next()) {

        int n = yScanner.activeCount;

        vgerPrim prim = {
            .type = vgerPathFill,
            .paint = paint.index,
            .xform = xform,
            .start = cvCount,
            .count = uint16_t(n)
        };

        if(primCount[currentLayer] < maxPrims and cvCount+n*3 < maxCvs) {

            Interval xInt{FLT_MAX, -FLT_MAX};

            for(int a = yScanner.first; a != -1; a = yScanner.segments[a].next) {

                assert(a < yScanner.segments.size());
                for(int i=0;i<3;++i) {
                    auto p = yScanner.segments[a].cvs[i];
                    addCV(p);
                    xInt.a = std::min(xInt.a, p.x);
                    xInt.b = std::max(xInt.b, p.x);
                }

            }

            BBox bounds;
            bounds.min.x = xInt.a;
            bounds.max.x = xInt.b;
            bounds.min.y = yScanner.interval.a;
            bounds.max.y = yScanner.interval.b;

            // Calculate the prim vertices at this stage,
            // as we do for glyphs.
            prim.quadBounds[0] = prim.texBounds[0] = bounds.min;
            prim.quadBounds[1] = prim.texBounds[1] = bounds.max;

            *(primPtr[currentLayer]++) = prim;
            primCount[currentLayer]++;
        }
    }

    assert(yScanner.activeCount == 0);

    yScanner.segments.clear();

}

void vger::fillForTile(vgerPaintIndex paint) {

    if(primCount[currentLayer] == maxPrims) {
        return;
    }

    vgerPrim prim = {
        .type = vgerPathFill,
        .paint = paint.index,
        .xform = addxform(txStack.back()),
        .start = cvCount,
        .count = static_cast<uint16_t>(yScanner.segments.size()),
        .width = 0
    };

    for(auto seg : yScanner.segments) {
        addCV(seg.cvs[0]);
        addCV(seg.cvs[1]);
        addCV(seg.cvs[2]);
    }

    auto bounds = sdPrimBounds(prim, (float2*) scenes[currentScene].cvs.contents).inset(-10);
    prim.quadBounds[0] = prim.texBounds[0] = bounds.min;
    prim.quadBounds[1] = prim.texBounds[1] = bounds.max;

    *(primPtr[currentLayer]++) = prim;
    primCount[currentLayer]++;

    yScanner.segments.clear();

}

void vgerMoveTo(vgerContext vg, float2 pt) {
    vg->pen = pt;
}

void vgerLineTo(vgerContext vg, vector_float2 b) {
    vgerQuadTo(vg, (vg->pen + b)/2, b);
}

void vgerQuadTo(vgerContext vg, float2 b, float2 c) {
    vg->yScanner.segments.push_back({vg->pen, b, c});
    vg->pen = c;
}

void vgerCubicApproxTo(vgerContext vg, float2 b, float2 c, float2 d) {
    float2 cubic[4] = {vg->pen, b, c, d};
    float2 q[6];
    approx_cubic(cubic, q);
    vgerQuadTo(vg, q[1], q[2]);
    vgerQuadTo(vg, q[4], q[5]);
}

void vgerFill(vgerContext vg, vgerPaintIndex paint) {
    vg->fill(paint);
}

void vgerFillForTile(vgerContext vg, vgerPaintIndex paint) {
    vg->fillForTile(paint);
}

void vgerEncode(vgerContext vg, id<MTLCommandBuffer> buf, MTLRenderPassDescriptor* pass) {
    vg->encode(buf, pass, false);
}

void vger::encode(id<MTLCommandBuffer> buf, MTLRenderPassDescriptor* pass, bool glow) {

    [glyphCache update:buf];

    auto glyphRects = [glyphCache getRects];
    auto& scene = scenes[currentScene];

    bool computeGlyphBounds = false;
    if(!computedGlyphBounds) {
        computeGlyphBounds = true;
        computedGlyphBounds = true;
    }

    for(int layer = 0; layer < layerCount; ++layer) {

        if(computeGlyphBounds) {
            auto primp = (vgerPrim*) scene.prims[layer].contents;
            for(int i=0;i<primCount[layer];++i) {
                auto& prim = primp[i];
                if(prim.type == vgerGlyph) {
                    auto r = glyphRects[prim.glyph-1];
                    for(int i=0;i<2;++i) {
                        prim.texBounds[i] += float2{float(r.x), float(r.y)};
                    }
                }
            }
        }

        if(layer) {
            pass.colorAttachments[0].loadAction = MTLLoadActionLoad;
        }

        [(glow ? glowRenderer : renderer) encodeTo:buf
                                              pass:pass
                                             scene:scene
                                             count:primCount[layer]
                                             layer:layer
                                          textures:textures
                                      glyphTexture:[glyphCache getAltas]
                                        windowSize:windowSize
                                              glow:glow];
    }
}

void vgerEncodeGlowPass(vgerContext vg, id<MTLCommandBuffer> buf, MTLRenderPassDescriptor* pass) {
    vg->encode(buf, pass, true);
}

void vgerEncodeTileRender(vgerContext vg, id<MTLCommandBuffer> buf, id<MTLTexture> renderTexture) {
    vg->encodeTileRender(buf, renderTexture);
}

void vger::encodeTileRender(id<MTLCommandBuffer> buf, id<MTLTexture> renderTexture) {

    // Create tile renderer on demand, since it uses a lot of RAM.
    if(tileRenderer == nil) {
        tileRenderer = [[vgerTileRenderer alloc] initWithDevice:device];
    }

    [tileRenderer encodeTo:buf
                     scene:scenes[currentScene]
                     count:primCount[currentLayer]
                     layer:0
                  textures:textures
              glyphTexture:[glyphCache getAltas]
             renderTexture:renderTexture
                windowSize:windowSize];

}

void vgerTranslate(vgerContext vg, float2 t) {
    auto M = matrix_identity_float3x3;
    M.columns[2] = vector3(t, 1);

    auto& A = vg->txStack.back();
    A = matrix_multiply(A, M);
}

/// Scales current coordinate system.
void vgerScale(vgerContext vg, float2 s) {
    auto M = matrix_identity_float3x3;
    M.columns[0].x = s.x;
    M.columns[1].y = s.y;

    auto& A = vg->txStack.back();
    A = matrix_multiply(A, M);
}

void vgerRotate(vgerContext vg, float theta) {
    auto M = matrix_identity_float3x3;
    M.columns[0].x = cosf(theta);
    M.columns[0].y = sinf(theta);
    M.columns[1].x = - M.columns[0].y;
    M.columns[1].y = M.columns[0].x;

    auto& A = vg->txStack.back();
    A = matrix_multiply(A, M);
}

/// Transforms a point according to the current transformation.
float2 vgerTransform(vgerContext vg, float2 p) {
    auto& M = vg->txStack.back();
    auto q = matrix_multiply(M, float3{p.x,p.y,1.0});
    return {q.x/q.z, q.y/q.z};
}

simd_float3x2 vgerCurrentTransform(vgerContext vg) {
    auto& M = vg->txStack.back();
    return {
        M.columns[0].xy, M.columns[1].xy, M.columns[2].xy
    };
}

void vgerSave(vgerContext vg) {
    vg->txStack.push_back(vg->txStack.back());
}

void vgerRestore(vgerContext vg) {
    vg->txStack.pop_back();
    assert(!vg->txStack.empty());
}

size_t vgerStackDepth(vgerContext vg) {
    return vg->txStack.size();
}

void vgerSetLayerCount(vgerContext vg, int layerCount) {
    assert(layerCount > 0);
    assert(layerCount <= VGER_MAX_LAYERS);
    vg->layerCount = layerCount;
}

void vgerSetLayer(vgerContext vg, int layer) {
    assert(layer < VGER_MAX_LAYERS);
    assert(layer >= 0);
    vg->currentLayer = layer;
}

id<MTLTexture> vgerGetGlyphAtlas(vgerContext vg) {
    return [vg->glyphCache getAltas];
}

id<MTLTexture> vgerGetCoarseDebugTexture(vgerContext vg) {
    return [vg->tileRenderer getDebugTexture];
}

vgerPaintIndex vgerColorPaint(vgerContext vg, float4 color) {

    vgerPaint p;
    p.xform = matrix_identity_float3x3;
    p.innerColor = color;
    p.outerColor = color;
    p.image = -1;
    p.glow = 0;

    return vg->addPaint(p);
}

vgerPaintIndex vgerLinearGradient(vgerContext vg,
                                  float2 start,
                                  float2 end,
                                  float4 innerColor,
                                  float4 outerColor,
                                  float glow) {

    return vg->addPaint(makeLinearGradient(start, end, innerColor, outerColor, glow));

}

vgerPaintIndex vgerImagePattern(vgerContext vg, float2 origin, float2 size, float angle,
                                vgerImageIndex image, float alpha) {

    return vg->addPaint(makeImagePattern(origin, size, angle, image, alpha));
}

vgerPaintIndex vgerGrid(vgerContext vg, vector_float2 origin, vector_float2 size,
                        float width, vector_float4 color) {

    vgerPaint p;
    p.image = -2;
    p.innerColor = color;
    p.xform = {
        float3{ 1/size.x, 0, 0},
        float3{ 0, 1/size.y, 0},
        float3{ -origin.x, -origin.y, 1}
    };
    p.glow = 0;

    return vg->addPaint(p);
}
