//  Copyright © 2021 Audulus LLC. All rights reserved.

#import <XCTest/XCTest.h>
#import <simd/simd.h>
#include "vger_types.h"

#import "../../Sources/vger/sdf.h"

@interface sdfTests : XCTestCase

@end

@implementation sdfTests

- (void) testWire {

    float d = sdWire(float2{0,0}, float2{0,0}, float2{1,1});
    XCTAssertEqualWithAccuracy(d, 0, 0.1);
    
    d = sdWire(float2{1,1}, float2{0,0}, float2{1,1});
    XCTAssertEqualWithAccuracy(d, 0, 0.1);

    d = sdWire(float2{0.5,0.5}, float2{0,0}, float2{1,1});
    XCTAssertEqualWithAccuracy(d, 0, 0.1);

}

- (void) testSolveQuadratic {

    float epsilon = 1e-5;

    float2 x = solve_quadratic(-1, 0, 1);
    XCTAssertTrue(simd_equal(x, float2{-1, 1}));

    x = solve_quadratic(0, 0, 1);
    XCTAssertEqual(x[0], 0);
    XCTAssert(isnan(x[1]));

    x = solve_quadratic(-5.0, 0.0, 1.0);
    XCTAssertEqualWithAccuracy(x[0], -sqrtf(5.0), epsilon);
    XCTAssertEqualWithAccuracy(x[1], sqrtf(5.0), epsilon);

    x = solve_quadratic(5.0, 0.0, 1.0);
    XCTAssert(isnan(x[0]));
    XCTAssert(isnan(x[1]));

    x = solve_quadratic(5.0, 1.0, 0.0);
    XCTAssertEqualWithAccuracy(x[0], -5.0, epsilon);
    XCTAssert(isnan(x[1]));

    x = solve_quadratic(1.0, 2.0, 1.0);
    XCTAssertEqualWithAccuracy(x[0], -1.0, epsilon);
    XCTAssert(isnan(x[1]));
    
}

- (void) testBezierIntersect {

    float epsilon = 1e-5;

    auto t = bezierIntersect(float2{0,0}, float2{0,0}, float2{1,1}, 0.0);
    XCTAssertEqual(t[0], 0.0);
    XCTAssert(isnan(t[1]));

    t = bezierIntersect(float2{0,0}, float2{0,0}, float2{1,1}, 1.0);
    XCTAssertTrue(length(t - float2{-1.0, 1.0}) < epsilon);

    t = bezierIntersect(float2{0,0}, float2{0,0}, float2{1,1}, 0.5);
    XCTAssertTrue(length(t - float2{-sqrtf(2)/2, sqrtf(2)/2}) < epsilon);

    t = bezierIntersect(float2{0,0}, float2{0,0}, float2{1,1}, -1);
    XCTAssertTrue(isnan(t.x));
    XCTAssertTrue(isnan(t.y));

    t = bezierIntersect(float2{0,0}, float2{1,0}, float2{1,1}, 0.0);
    XCTAssertEqual(t[0], 0.0);
    XCTAssert(isnan(t[1]));

    t = bezierIntersect(float2{0,0}, float2{1,0}, float2{1,1}, 1.0);
    XCTAssertTrue(length(t - float2{-1.0, 1.0}) < epsilon);

    t = bezierIntersect(float2{0,0}, float2{1,1}, float2{2,0}, 0.1);

    float2 x = bezier(float2{0,0}, float2{1,1}, float2{2,0}, 0.5);

    XCTAssertEqual(bezierTest(float2{0,0}, float2{1,0}, float2{1,1}, float2{0, .5}), 1);
    XCTAssertEqual(bezierTest(float2{0,0}, float2{1,0}, float2{1,1}, float2{0, -1}), 0);
    XCTAssertEqual(bezierTest(float2{0,0}, float2{1,0}, float2{1,1}, float2{0, 2}), 0);
    XCTAssertEqual(bezierTest(float2{0,0}, float2{1,1}, float2{2,0}, float2{0, .1}), 2);

    // Vertical line, right of point.
    XCTAssertEqual(bezierTest(float2{1,-1}, float2{1,0}, float2{1,1}, float2{0, 0}), 1);

    // Vertical line, left of point.
    XCTAssertEqual(bezierTest(float2{-1,-1}, float2{-1,0}, float2{-1,1}, float2{0, 0}), 0);

    // Horizontal line.
    XCTAssertEqual(bezierTest(float2{1,0}, float2{2,0}, float2{3,1}, float2{0, 0}), 0);

    // Diagonal line, right of point.
    XCTAssertEqual(bezierTest(float2{1, -1}, float2{2,0}, float2{3,1}, float2{0, 0}), 1);

    // Diagonal in Z
    XCTAssertEqual(bezierTest(float2{0, 1.308}, float2{2.19, 4.374}, float2{4.38, 7.44}, float2{0,5.0}), 1);

    t = bezierIntersect(float2{0,0}, float2{0,1}, float2{0,2}, 1.0);
    XCTAssertEqual(t[0], 0.5);
}

@end
