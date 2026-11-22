// The toolbar a device gets: its clusters' own controls (actions that may
// need an ability) and each panel's control, placed in the cluster the panel
// names — every control only when the device has the ability it needs. A new
// panel brings its own control; nothing here changes.

/**
 * The clusters for a device with `abilities` (null: the server listed none,
 * so everything shows), and the ids of the controls that go.
 */
export function toolbarFor(clusters, { panels, abilities }) {
  const can = (needs) => !needs || abilities === null || abilities.includes(needs);
  const hidden = [];
  const kept = clusters.map((cluster) => {
    const own = cluster.members;
    const placed = panels.filter((panel) => panel.cluster === cluster.id).map((panel) => ({
      id: 'native' + panel.slot + 'Toggle', label: panel.label, role: 'state', needs: panel.needs,
    }));
    const members = [...own, ...placed].filter((member) => {
      if (can(member.needs)) return true;
      hidden.push(member.id);
      return false;
    });
    return { ...cluster, members };
  }).filter((cluster) => cluster.members.length);
  return { clusters: kept, hidden };
}
