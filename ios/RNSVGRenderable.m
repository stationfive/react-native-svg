/**
 * Copyright (c) 2015-present, Horcrux.
 * All rights reserved.
 *
 * This source code is licensed under the MIT-style license found in the
 * LICENSE file in the root directory of this source tree.
 */

#import "RNSVGRenderable.h"
#import "RNSVGClipPath.h"
#import "RNSVGFilter.h"
#import "RNSVGMask.h"
#import "RNSVGViewBox.h"
#import "LuminanceToAlpha.h"
#import "RNSVGVectorEffect.h"

@implementation RNSVGRenderable
{
    NSMutableDictionary *_originProperties;
    NSArray<NSString *> *_lastMergedList;
    NSArray<NSString *> *_attributeList;
    NSArray<RNSVGLength *> *_sourceStrokeDashArray;
    CGFloat *_strokeDashArrayData;
    CGPathRef _srcHitPath;
    CGPathRef _hitArea;
    CIContext* ciContext;
}

- (id)init
{
    if (self = [super init]) {
        _fillOpacity = 1;
        _strokeOpacity = 1;
        _strokeWidth = [RNSVGLength lengthWithNumber:1];
        _fillRule = kRNSVGCGFCRuleNonzero;
    }
    return self;
}

- (void)invalidate
{
    _sourceStrokeDashArray = nil;
    if (self.dirty || self.merging) {
        return;
    }
    _srcHitPath = nil;
    [super invalidate];
    self.dirty = true;
}

- (void)setFill:(RNSVGBrush *)fill
{
    if (fill == _fill) {
        return;
    }
    [self invalidate];
    _fill = fill;
}

- (void)setFillOpacity:(CGFloat)fillOpacity
{
    if (fillOpacity == _fillOpacity) {
        return;
    }
    [self invalidate];
    _fillOpacity = fillOpacity;
}

- (void)setFillRule:(RNSVGCGFCRule)fillRule
{
    if (fillRule == _fillRule) {
        return;
    }
    [self invalidate];
    _fillRule = fillRule;
}

- (void)setStroke:(RNSVGBrush *)stroke
{
    if (stroke == _stroke) {
        return;
    }
    [self invalidate];
    _stroke = stroke;
}

- (void)setStrokeOpacity:(CGFloat)strokeOpacity
{
    if (strokeOpacity == _strokeOpacity) {
        return;
    }
    [self invalidate];
    _strokeOpacity = strokeOpacity;
}

- (void)setStrokeWidth:(RNSVGLength*)strokeWidth
{
    if ([strokeWidth isEqualTo:_strokeWidth]) {
        return;
    }
    [self invalidate];
    _strokeWidth = strokeWidth;
}

- (void)setStrokeLinecap:(CGLineCap)strokeLinecap
{
    if (strokeLinecap == _strokeLinecap) {
        return;
    }
    [self invalidate];
    _strokeLinecap = strokeLinecap;
}

- (void)setStrokeJoin:(CGLineJoin)strokeLinejoin
{
    if (strokeLinejoin == _strokeLinejoin) {
        return;
    }
    [self invalidate];
    _strokeLinejoin = strokeLinejoin;
}

- (void)setStrokeMiterlimit:(CGFloat)strokeMiterlimit
{
    if (strokeMiterlimit == _strokeMiterlimit) {
        return;
    }
    [self invalidate];
    _strokeMiterlimit = strokeMiterlimit;
}

- (void)setStrokeDasharray:(NSArray<RNSVGLength *> *)strokeDasharray
{
    if (strokeDasharray == _strokeDasharray) {
        return;
    }
    [self invalidate];
    _strokeDasharray = strokeDasharray;
}

- (void)setStrokeDashoffset:(CGFloat)strokeDashoffset
{
    if (strokeDashoffset == _strokeDashoffset) {
        return;
    }
    [self invalidate];
    _strokeDashoffset = strokeDashoffset;
}

- (void)setVectorEffect:(RNSVGVectorEffect)vectorEffect
{
    if (vectorEffect == _vectorEffect) {
        return;
    }
    [self invalidate];
    _vectorEffect = vectorEffect;
}

- (void)setPropList:(NSArray<NSString *> *)propList
{
    if (propList == _propList) {
        return;
    }

    _propList = _attributeList = propList;
    [self invalidate];
}

- (void)dealloc
{
    CGPathRelease(_hitArea);
    _sourceStrokeDashArray = nil;
    if (_strokeDashArrayData) {
        free(_strokeDashArrayData);
    }
    _strokeDashArrayData = nil;
}

static CGImageRef renderToImage(RNSVGRenderable *object,
                                CGSize bounds,
                                CGRect rect,
                                CGRect* clip)
{
    UIGra
      phicsBeginImageContextWithOptions(bounds, NO, 1.0);
    CGContextRef cgContext = UIGraphicsGetCurrentContext();
    CGContextTranslateCTM(cgContext, 0.0, bounds.height);
    CGContextScaleCTM(cgContext, 1.0, -1.0);
    if (clip) {
        CGContextClipToRect(cgContext, *clip);
    }
    [object renderLayerTo:cgContext rect:rect];
    CGImageRef contentImage = CGBitmapContextCreateImage(cgContext);
    UIGraphicsEndImageContext();
    return contentImage;
}

+ (CIContext *)sharedCIContext {
    static CIContext *sharedCIContext = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        sharedCIContext = [[CIContext alloc] init];
    });

    return sharedCIContext;
}

- (void)renderTo:(CGContextRef)context rect:(CGRect)rect
{
    self.dirty = false;
    // This needs to be painted on a layer before being composited.
    CGContextSaveGState(context);
    CGContextConcatCTM(context, self.matrix);
    CGContextConcatCTM(context, self.transforms);
    CGContextSetAlpha(context, self.opacity);

    [self beginTransparencyLayer:context];

    if (self.mask || self.filter) {
        CGRect bounds = CGContextGetClipBoundingBox(context);
        CGSize boundsSize = bounds.size;
        CGFloat width = boundsSize.width;
        CGFloat height = boundsSize.height;
        CGRect drawBounds = CGRectMake(0, 0, width, height);

        // Render content of current SVG Renderable to image
        CGImageRef currentContent = renderToImage(self, boundsSize, rect, nil);
        CIImage *contentSrcImage = [CIImage imageWithCGImage:currentContent];

        BOOL hasSourceGraphicAsLastOutput = false;
        if (self.filter) {
            // https://www.w3.org/TR/SVG11/filters.html
            RNSVGFilter *_filterNode = (RNSVGFilter*)[self.svgView getDefinedFilter:self.filter];
            CGImageRef backgroundImage = CGBitmapContextCreateImage(context);
            CIImage *background = [CIImage imageWithCGImage:backgroundImage];
            contentSrcImage = [_filterNode applyFilter:contentSrcImage background:background];
            hasSourceGraphicAsLastOutput = [_filterNode hasSourceGraphicAsLastOutput];
        }

        if (self.mask) {
            // https://www.w3.org/TR/SVG11/masking.html#MaskElement
            RNSVGMask *_maskNode = (RNSVGMask*)[self.svgView getDefinedMask:self.mask];
            CGFloat x = [self relativeOn:[_maskNode x] relative:width];
            CGFloat y = [self relativeOn:[_maskNode y] relative:height];
            CGFloat w = [self relativeOn:[_maskNode width] relative:width];
            CGFloat h = [self relativeOn:[_maskNode height] relative:height];

            // Clip to mask bounds and render the mask
            CGRect maskBounds = CGRectMake(x, y, w, h);
            CGImageRef maskContent = renderToImage(_maskNode, boundsSize, rect, &maskBounds);
            CIImage *maskSrcImage = [CIImage imageWithCGImage:maskContent];

            // Apply luminanceToAlpha filter primitive
            // https://www.w3.org/TR/SVG11/filters.html#feColorMatrixElement
            CIImage *alphaMask = transformImageIntoAlphaMask(maskSrcImage);
            CIImage *composite = applyBlendWithAlphaMask(contentSrcImage, alphaMask);

            // Create masked image and release memory
            CGImageRef compositeImage = [[RNSVGRenderable sharedCIContext] createCGImage:composite fromRect:drawBounds];

            // Render composited result into current render context
            CGContextDrawImage(context, drawBounds, compositeImage);
            CGImageRelease(compositeImage);
            CGImageRelease(maskContent);
        } else {
            // Render filtered result into current render context
            CGImageRef filteredImage = [[RNSVGRenderable sharedCIContext] createCGImage:contentSrcImage fromRect:drawBounds];
            CGContextDrawImage(context, drawBounds, filteredImage);
            CGImageRelease(filteredImage);
        }

        CGImageRelease(currentContent);
        if (hasSourceGraphicAsLastOutput) {
            [self renderLayerTo:context rect:rect];
        }
    } else {
        [self renderLayerTo:context rect:rect];
    }
    [self endTransparencyLayer:context];

    CGContextRestoreGState(context);
}

- (void)prepareStrokeDash:(NSUInteger)count strokeDasharray:(NSArray<RNSVGLength *> *)strokeDasharray {
    if (strokeDasharray != _sourceStrokeDashArray) {
        CGFloat *dash = _strokeDashArrayData;
        _strokeDashArrayData = realloc(dash, sizeof(CGFloat) * count);
        if (!_strokeDashArrayData) {
            free(dash);
            return;
        }
        _sourceStrokeDashArray = strokeDasharray;
        for (NSUInteger i = 0; i < count; i++) {
            _strokeDashArrayData[i] = (CGFloat)[self relativeOnOther:strokeDasharray[i]];
        }
    }
}

- (void)renderLayerTo:(CGContextRef)context rect:(CGRect)rect
{
    CGPathRef path = self.path;
    if (!path) {
        path = [self getPath:context];
        if (!self.path) {
            self.path = CGPathRetain(path);
        }
        [self setHitArea:path];
        const CGRect fillBounds = CGPathGetBoundingBox(path);
        const CGRect strokeBounds = CGPathGetBoundingBox(self.strokePath);
        self.pathBounds = CGRectUnion(fillBounds, strokeBounds);
    }
    const CGRect pathBounds = self.pathBounds;

    CGAffineTransform current = CGContextGetCTM(context);
    CGAffineTransform svgToClientTransform = CGAffineTransformConcat(current, self.svgView.invInitialCTM);
    CGRect clientRect = CGRectApplyAffineTransform(pathBounds, svgToClientTransform);

    self.clientRect = clientRect;

    if (_vectorEffect == kRNSVGVectorEffectNonScalingStroke) {
        path = CGPathCreateCopyByTransformingPath(path, &svgToClientTransform);
        CGContextConcatCTM(context, CGAffineTransformInvert(svgToClientTransform));
    }

    CGAffineTransform vbmatrix = self.svgView.getViewBoxTransform;
    CGAffineTransform transform = CGAffineTransformConcat(self.matrix, self.transforms);
    CGAffineTransform matrix = CGAffineTransformConcat(transform, vbmatrix);

    CGRect bounds = CGRectMake(0, 0, CGRectGetWidth(clientRect), CGRectGetHeight(clientRect));
    CGPoint mid = CGPointMake(CGRectGetMidX(pathBounds), CGRectGetMidY(pathBounds));
    CGPoint center = CGPointApplyAffineTransform(mid, matrix);

    self.bounds = bounds;
    if (!isnan(center.x) && !isnan(center.y)) {
        self.center = center;
    }
    self.frame = clientRect;

    if (!self.fill && !self.stroke) {
        return;
    }

    if (self.opacity == 0) {
        return;
    }

    CGPathDrawingMode mode = kCGPathStroke;
    BOOL fillColor = NO;
    [self clip:context];

    BOOL evenodd = self.fillRule == kRNSVGCGFCRuleEvenodd;

    if (self.fill) {
        if (self.fill.class == RNSVGBrush.class) {
            CGContextSetFillColorWithColor(context, [self.tintColor CGColor]);
            fillColor = YES;
        } else {
            fillColor = [self.fill applyFillColor:context opacity:self.fillOpacity];
        }

        if (fillColor) {
            mode = evenodd ? kCGPathEOFill : kCGPathFill;
        } else {
            CGContextSaveGState(context);
            CGContextAddPath(context, path);
            CGContextClip(context);
            [self.fill paint:context
                     opacity:self.fillOpacity
                     painter:[self.svgView getDefinedPainter:self.fill.brushRef]
                      bounds:pathBounds
             ];
            CGContextRestoreGState(context);

            if (!self.stroke) {
                return;
            }
        }
    }

    if (self.stroke) {
        CGFloat width = self.strokeWidth ? [self relativeOnOther:self.strokeWidth] : 1;
        CGContextSetLineWidth(context, width);
        CGContextSetLineCap(context, self.strokeLinecap);
        CGContextSetLineJoin(context, self.strokeLinejoin);
        NSArray<RNSVGLength *>* strokeDasharray = self.strokeDasharray;
        NSUInteger count = strokeDasharray.count;

        if (count) {
            [self prepareStrokeDash:count strokeDasharray:strokeDasharray];
            if (_strokeDashArrayData) {
                CGContextSetLineDash(context, self.strokeDashoffset, _strokeDashArrayData, count);
            }
        }

        if (!fillColor) {
            CGContextAddPath(context, path);
            CGContextReplacePathWithStrokedPath(context);
            CGContextClip(context);
        }

        BOOL strokeColor;

        if (self.stroke.class == RNSVGBrush.class) {
            CGContextSetStrokeColorWithColor(context,[self.tintColor CGColor]);
            strokeColor = YES;
        } else {
            strokeColor = [self.stroke applyStrokeColor:context opacity:self.strokeOpacity];
        }

        if (strokeColor && fillColor) {
            mode = evenodd ? kCGPathEOFillStroke : kCGPathFillStroke;
        } else if (!strokeColor) {
            // draw fill
            if (fillColor) {
                CGContextAddPath(context, path);
                CGContextDrawPath(context, mode);
            }

            // draw stroke
            CGContextAddPath(context, path);
            CGContextReplacePathWithStrokedPath(context);
            CGContextClip(context);

            [self.stroke paint:context
                       opacity:self.strokeOpacity
                       painter:[self.svgView getDefinedPainter:self.stroke.brushRef]
                        bounds:pathBounds
             ];
            return;
        }
    }

    CGContextAddPath(context, path);
    CGContextDrawPath(context, mode);
}

- (void)setHitArea:(CGPathRef)path
{
    if (_srcHitPath == path) {
        return;
    }
    _srcHitPath = path;
    CGPathRelease(_hitArea);
    CGPathRelease(self.strokePath);
    _hitArea = CGPathCreateCopy(path);
    self.strokePath = nil;
    if (self.stroke && self.strokeWidth) {
        // Add stroke to hitArea
        CGFloat width = [self relativeOnOther:self.strokeWidth];
        self.strokePath = CGPathRetain(CFAutorelease(CGPathCreateCopyByStrokingPath(path, nil, width, self.strokeLinecap, self.strokeLinejoin, self.strokeMiterlimit)));
        // TODO add dashing
        // CGPathCreateCopyByDashingPath(CGPathRef  _Nullable path, const CGAffineTransform * _Nullable transform, CGFloat phase, const CGFloat * _Nullable lengths, size_t count)
    }
}

- (BOOL)isUserInteractionEnabled
{
    return NO;
}

// hitTest delegate
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event
{
    if (!_hitArea) {
        return nil;
    }

    if (self.active) {
        if (!event) {
            self.active = NO;
        }
        return self;
    }

    CGPoint transformed = CGPointApplyAffineTransform(point, self.invmatrix);
    transformed = CGPointApplyAffineTransform(transformed, self.invTransform);

    if (!CGRectContainsPoint(self.pathBounds, transformed)) {
        return nil;
    }

    BOOL evenodd = self.fillRule == kRNSVGCGFCRuleEvenodd;
    if (!CGPathContainsPoint(_hitArea, nil, transformed, evenodd) &&
        !CGPathContainsPoint(self.strokePath, nil, transformed, NO)) {
        return nil;
    }

    if (self.clipPath) {
        RNSVGClipPath *clipNode = (RNSVGClipPath*)[self.svgView getDefinedClipPath:self.clipPath];
        if ([clipNode isSimpleClipPath]) {
            CGPathRef clipPath = [self getClipPath];
            if (clipPath && !CGPathContainsPoint(clipPath, nil, transformed, clipNode.clipRule == kRNSVGCGFCRuleEvenodd)) {
                return nil;
            }
        } else {
            RNSVGRenderable *clipGroup = (RNSVGRenderable*)clipNode;
            if (![clipGroup hitTest:transformed withEvent:event]) {
                return nil;
            }
        }
    }

    return self;
}

- (NSArray<NSString *> *)getAttributeList
{
    return _attributeList;
}

- (void)mergeProperties:(__kindof RNSVGRenderable *)target
{
    NSArray<NSString *> *targetAttributeList = [target getAttributeList];

    if (targetAttributeList.count == 0) {
        return;
    }
    self.merging = true;

    NSMutableArray* attributeList = [self.propList mutableCopy];
    _originProperties = [[NSMutableDictionary alloc] init];

    for (NSString *key in targetAttributeList) {
        [_originProperties setValue:[self valueForKey:key] forKey:key];
        if (![attributeList containsObject:key]) {
            [attributeList addObject:key];
            [self setValue:[target valueForKey:key] forKey:key];
        }
    }

    _lastMergedList = targetAttributeList;
    _attributeList = [attributeList copy];
    self.merging = false;
}

- (void)resetProperties
{
    self.merging = true;
    for (NSString *key in _lastMergedList) {
        [self setValue:[_originProperties valueForKey:key] forKey:key];
    }

    _lastMergedList = nil;
    _attributeList = _propList;
    self.merging = false;
}

static CIImage *transparentImage()
{
    static CIImage *transparentImage = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CIFilter *transparent = [CIFilter filterWithName:@"CIConstantColorGenerator"];
        [transparent setValue:[CIColor colorWithRed:0.0 green:0.0 blue:0.0 alpha:0.0] forKey:@"inputColor"];
        transparentImage = [transparent valueForKey:@"outputImage"];
    });
    return transparentImage;
}

static CIImage *blackImage()
{
    static CIImage *blackImage = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CIFilter *black = [CIFilter filterWithName:@"CIConstantColorGenerator"];
        [black setValue:[CIColor colorWithRed:0.0 green:0.0 blue:0.0 alpha:1.0] forKey:@"inputColor"];
        blackImage = [black valueForKey:@"outputImage"];
    });
    return blackImage;
}

static CIImage *transformImageIntoAlphaMask(CIImage *inputImage)
{
    CIImage *blackBackground = blackImage();
    CIFilter *layerOverBlack = [CIFilter filterWithName:@"CISourceOverCompositing"];
    [layerOverBlack setValue:blackBackground forKey:@"inputBackgroundImage"];
    [layerOverBlack setValue:inputImage forKey:@"inputImage"];
    return applyLuminanceToAlphaFilter([layerOverBlack valueForKey:@"outputImage"]);
}

static CIImage *applyBlendWithAlphaMask(CIImage *inputImage, CIImage *inputMaskImage)
{
    CIImage *transparent = transparentImage();
    CIFilter *blendWithAlphaMask = [CIFilter filterWithName:@"CIBlendWithAlphaMask"];
    [blendWithAlphaMask setDefaults];
    [blendWithAlphaMask setValue:inputImage forKey:@"inputImage"];
    [blendWithAlphaMask setValue:transparent forKey:@"inputBackgroundImage"];
    [blendWithAlphaMask setValue:inputMaskImage forKey:@"inputMaskImage"];
    return [blendWithAlphaMask valueForKey:@"outputImage"];
}

@end
