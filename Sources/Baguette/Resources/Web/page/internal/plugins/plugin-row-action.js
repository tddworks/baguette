// PluginRowAction — what clicking a row in a plugin panel means.
//
// A panel declares one `rowAction` for all its rows; each row then
// carries the material that action needs (a `frame` to box or aim at, a
// `copy` string to put on the clipboard). Whether a row can be clicked
// at all depends on both: a `tap` row without a frame has nothing to
// aim at, and a `copy` row never needed one.
//
// Split out of page/internal/plugins/plugins-rail.js so the decision is testable without a
// DOM. page/internal/plugins/plugins-rail.js keeps the rendering and the clipboard/gesture
// plumbing; this only says what should happen.
//
// Lives at the web root beside page/internal/plugins/plugins-rail.js rather than in a
// `plugins/` folder: `/plugins/:file` and the plugin API's
// `/plugins/:id/commands/:cmd` would bind the same router slot under
// two different names, which Hummingbird rejects outright (see the
// `staticAssetSubdirectories` note in Server.swift).
class PluginRowAction {
  /** @param {string|undefined} name  the panel's declared `rowAction` */
  constructor(name) {
    this.name = name;
  }

  /**
   * What clicking `row` should do, or `null` when the answer is
   * "nothing" — an unknown action, or a row missing what the action
   * needs. A manifest is untrusted text, so an action baguette
   * doesn't know is inert rather than resolved to the nearest match.
   *
   * @returns {{kind:'highlight', frame:object}
   *          |{kind:'tap', point:{x:number,y:number}}
   *          |{kind:'copy', text:string}
   *          |{kind:'run', command:string, args:object}
   *          |{kind:'fill', text:string}
   *          |null}
   */
  intent(row) {
    if (!row) return null;
    switch (this.name) {
      case 'highlight':
        return row.frame ? { kind: 'highlight', frame: row.frame } : null;
      case 'tap':
        return row.frame ? { kind: 'tap', point: PluginRowAction.centre(row.frame) } : null;
      case 'copy':
        return row.copy ? { kind: 'copy', text: row.copy } : null;
      case 'run':
        // No frame required — a settings row has no on-screen rect,
        // and demanding one would make every such row inert. Args
        // default to {} so the caller has a single shape to post.
        return row.run ? { kind: 'run', command: row.run, args: row.args || {} } : null;
      case 'fill':
        // The row's own text, never its title: a title is display
        // text, so truncating or translating it would silently change
        // what gets typed into the field.
        return row.fill ? { kind: 'fill', text: row.fill } : null;
      default:
        return null;
    }
  }

  /** Whether this row should look and behave as clickable. */
  actionable(row) {
    return this.intent(row) !== null;
  }

  /**
   * The middle of a device-point frame. Gesture coordinates are in
   * the same space a row's frame arrives in, so aiming at a row is
   * arithmetic, not a projection.
   */
  static centre(frame) {
    return {
      x: frame.x + (frame.width || 0) / 2,
      y: frame.y + (frame.height || 0) / 2,
    };
  }
}

export { PluginRowAction };
