// PointerShape — the Mac's pointer as it looks now (an arrow, an I-beam over
// text, a hand over a link), heard on `/mac/pointer` and given to the page's
// own pointer (LocalPointer): the browser's cursor for a mouse, a drawn image
// for a finger. Each image is fetched once by id.
(function (root) {
  'use strict';

  const PointerShape = {
    /** A shape from a socket message; null for anything else. */
    fromMessage(text) {
      let message = null;
      try { message = JSON.parse(text); } catch { return null; }
      if (!message || message.type !== 'pointer' || !message.id) return null;
      return {
        id: message.id,
        image: '/mac/pointer/' + encodeURIComponent(message.id) + '.png',
        hotspot: { x: message.hotspot[0], y: message.hotspot[1] },
        size: { width: message.size[0], height: message.size[1] },
      };
    },

    /** How many image pixels make one of the shape's points. */
    density(pixelWidth, size) {
      return pixelWidth > 0 && size.width > 0 ? pixelWidth / size.width : 1;
    },

    /** The CSS cursor showing `shape`, pointing with its hotspot. */
    cursor(shape, density) {
      return '-webkit-image-set(url("' + shape.image + '") ' + density + 'x) ' +
          shape.hotspot.x + ' ' + shape.hotspot.y + ', default';
    },

    /** Follow the Mac's pointer shape: each change handed to `apply`. */
    follow(apply) {
      const scheme = location.protocol === 'https:' ? 'wss://' : 'ws://';
      const socket = new WebSocket(scheme + location.host + '/mac/pointer');
      let newest = 0;
      socket.onmessage = (e) => {
        const shape = PointerShape.fromMessage(e.data);
        if (!shape) return;
        const mine = ++newest;
        const image = new Image();
        // An older shape's image loading late never covers a newer shape.
        image.onload = () => { if (mine === newest) apply(shape, PointerShape.density(image.naturalWidth, shape.size)); };
        image.src = shape.image;
      };
      return { stop() { socket.close(); } };
    },
  };

  root.Baguette = root.Baguette || {};
  root.Baguette._PointerShape = PointerShape;
})(window);
