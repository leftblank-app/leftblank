"""LeftBlank Preview update channels in one signed Sparkle feed.

Nightly is Sparkle's default channel: its items carry no <sparkle:channel>.
Alpha items carry <sparkle:channel>alpha</sparkle:channel> and are offered
only to Preview apps that opt in. The feed holds the newest item of each
channel; a publisher replaces only its own channel's item.
"""
import re
import xml.etree.ElementTree as ET

SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', SPARKLE)
NIGHTLY, ALPHA = 'nightly', 'alpha'
CHANNELS = (NIGHTLY, ALPHA)
# Alpha publishes on every Mac-affecting merge; keep only the newest few.
KEEP_ALPHA_RELEASES = 5
ALPHA_TAG = re.compile(r'preview-alpha-([1-9][0-9]*\.[1-9][0-9]*)')
DOWNLOAD = re.compile(r'/releases/download/([^/]+)/')


def release_tag(build, channel):
    """The immutable GitHub release tag that hosts one Preview build."""
    if channel not in CHANNELS:
        raise ValueError(f'Unknown Preview channel {channel!r}')
    return ('preview-' if channel == NIGHTLY else 'preview-alpha-') + build


def build_key(build):
    return tuple(int(part) for part in build.split('.'))


def version(item):
    return item.findtext(f'{{{SPARKLE}}}version')


def item_channel(item):
    name = item.findtext(f'{{{SPARKLE}}}channel')
    return NIGHTLY if name is None else name.strip()


def items_by_channel(root):
    """Each channel's item; a feed published before channels existed is all nightly."""
    found = {}
    for item in root.findall('./channel/item') if root is not None else ():
        found[item_channel(item)] = item
    return found


def merge(current, new):
    """`new`'s single item replacing only its own channel's item in `current` (or None)."""
    (item,) = new.findall('./channel/item')
    items = items_by_channel(current)
    items[item_channel(item)] = item
    root = ET.Element('rss', version='2.0')
    channel = ET.SubElement(root, 'channel')
    for name in ('title', 'link'):
        ET.SubElement(channel, name).text = new.findtext(f'./channel/{name}')
    for kept in sorted(items.values(), key=lambda entry: build_key(version(entry)), reverse=True):
        channel.append(kept)
    ET.indent(root)
    return root


def superseded(current, channel, build):
    """Whether the published feed already offers an equal or newer build in this channel."""
    previous = items_by_channel(current).get(channel)
    return previous is not None and build_key(version(previous)) >= build_key(build)


def alpha_tags_to_prune(tags, feed, keep=KEEP_ALPHA_RELEASES):
    """Alpha release tags beyond the newest `keep`, never one the feed points to.
    Nightly `preview-<build>` releases are never pruned."""
    pointed = {DOWNLOAD.search(enclosure.attrib['url']).group(1) for enclosure in feed.iter('enclosure')}
    alpha = sorted((tag for tag in tags if ALPHA_TAG.fullmatch(tag)),
                   key=lambda tag: build_key(ALPHA_TAG.fullmatch(tag).group(1)), reverse=True)
    return [tag for tag in alpha[keep:] if tag not in pointed]
