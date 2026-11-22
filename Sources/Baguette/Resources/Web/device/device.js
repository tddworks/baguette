// Device — the thing the page shows, as its family built it: its listing
// (id, name, kind, abilities) and the roles its family gave it. A role its
// family can't perform is absent, never disabled. The page talks to roles
// and never reads the kind (docs/features/web-page/design.md §3).

/** A device of `family` from its `listing` (or none), with `roles`. */
export function deviceOf(listing, { id, family, ...roles }) {
  const listed = listing && Array.isArray(listing.abilities) ? listing.abilities : null;
  return {
    id,
    family,
    listing,
    abilities: listed || [],
    /** Whether the server lists the ability `name` for it — everything when it
     *  lists nothing, as the toolbar shows everything then. */
    can: (name) => listed === null || listed.includes(name),
    ...roles,
  };
}

/** A device described by its own listing as the server gives it now (the
 *  one it was made with when the server can't say): its name, its OS (or
 *  model), and whether it is running, in the words the power card reads. */
export async function describeListed(id, listing, devices) {
  let now = null;
  try { now = devices.listing ? await devices.listing(id) : null; } catch { /* as it was */ }
  return listedDescription(now || listing);
}

function listedDescription(listing) {
  const kind = (listing && listing.kind) || {};
  return {
    name: (listing && listing.name) || 'Device',
    runtime: kind.os || kind.model || '',
    state: listing && listing.state === 'ready' ? 'Booted' : 'Shutdown',
  };
}
