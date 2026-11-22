// MacFrameChoices — what a Mac display's frame picker offers: no frame,
// then each installed Mac frame the display fits (the server decides which,
// `/mac-frames.json`). The pick stays offered even when the display no
// longer fits it, so the user can see what it is in and leave it.
const MacFrameChoices = {
  /**
   * @param {string[]|undefined} frames  names the server says fit
   * @param {string|null} picked         the frame the display is in, or null
   * @returns {{label: string, pick: string|null, chosen: boolean}[]}
   */
  of(frames, picked) {
    const names = Array.isArray(frames) ? frames.slice() : [];
    if (picked && !names.includes(picked)) names.push(picked);
    return [{ label: 'No frame', pick: null, chosen: !picked }]
      .concat(names.map((name) => ({ label: name, pick: name, chosen: name === picked })));
  },
};

export { MacFrameChoices };
