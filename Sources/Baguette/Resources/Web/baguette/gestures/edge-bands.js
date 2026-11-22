// EdgeBands — the hot-zone thresholds for edge-stream detection (the
// home-indicator/notification-center swipe), and the orientation-aware
// classification of a point against them. Mouse and touch each construct
// their own EdgeBands (touch's ellipse-centroid coordinates need a wider
// band than a precise mouse cursor) and ask it to classify a point.

class EdgeBands {
  constructor(bottomBandNorm, topBandNorm) {
    this.bottomBandNorm = bottomBandNorm;
    this.topBandNorm = topBandNorm;
  }

  /**
   * @param {{xNorm:number,yNorm:number}} point
   * @param {string} orientation  from Screen.getOrientation()
   * @returns {'bottom'|'top'|null}
   */
  classify(point, orientation) {
    // portrait-upside-down rotates the physical home-indicator edge
    // (device "bottom") onto visual-left instead of visual-bottom.
    const inBottomBand = orientation === 'portrait-upside-down'
      ? point.xNorm <= (1 - this.bottomBandNorm)
      : point.yNorm >= this.bottomBandNorm;
    const inTopBand = orientation === 'portrait-upside-down'
      ? point.xNorm >= this.bottomBandNorm
      : point.yNorm <= this.topBandNorm;
    return inBottomBand ? 'bottom' : (inTopBand ? 'top' : null);
  }
}

export { EdgeBands };

