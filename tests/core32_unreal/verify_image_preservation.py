"""Сравнение всего FAT32-образа с неизменяемой копией до теста."""
import argparse
import hashlib
import json
import mmap
from collections import Counter
from pathlib import Path
import core32_image_test as h


class ReadOnlyImage(h.Fat32Image):
    def __init__(self, path):
        self.path = Path(path)
        self._file = self.path.open('rb')
        self.data = mmap.mmap(self._file.fileno(), 0, access=mmap.ACCESS_READ)
        self.bps = h.le16(self.data, 11)
        self.spc = self.data[13]
        self.reserved = h.le16(self.data, 14)
        self.fats = self.data[16]
        self.total_sectors = h.le32(self.data, 32)
        self.fat_size = h.le32(self.data, 36)
        self.root_cluster = h.le32(self.data, 44)
        self.first_data_sector = self.reserved + self.fats * self.fat_size
        self.cluster_size = self.bps * self.spc
        self.active, self.mirrored = h.select_active_fat(self)

    def cluster_chain(self, start):
        result, seen = [], set()
        limit = (self.total_sectors - self.first_data_sector) // self.spc + 2
        while 2 <= start < 0x0FFFFFF8:
            if start >= limit or start in seen:
                raise ValueError(f'Invalid/cyclic FAT chain at {start:#x}')
            seen.add(start)
            result.append(start)
            start = self.get_fat(start)
            if start < 2:
                raise ValueError('Allocated chain ends at a free/reserved link')
        return result

    def close(self):
        self.data.close()
        self._file.close()


def inventory(image):
    result, visited = {}, set()
    def walk(cluster, parent):
        if cluster in visited:
            raise ValueError('Directory cycle or cross-link')
        visited.add(cluster)
        raw = image.read_chain(cluster)
        for entry in image.parse_dir(cluster):
            if entry['name'] in ('.', '..'):
                continue
            path = (parent + '/' + entry['name']).upper()
            chain = image.cluster_chain(entry['cluster']) if entry['cluster'] else []
            begin = entry['lfn_start'] * 32
            record = raw[begin:begin + entry['entries'] * 32]
            payload = image.read_chain(entry['cluster']) if chain else b''
            result[path] = dict(chain=chain, record=record.hex(), size=entry['size'],
                                directory=bool(entry['attr'] & h.ATTR_DIRECTORY),
                                sha256=hashlib.sha256(payload).hexdigest())
            if entry['attr'] & h.ATTR_DIRECTORY:
                walk(entry['cluster'], path)
    walk(image.root_cluster, '')
    return result


def verify(before, after, mutable, protected):
    mutable = [p.upper().rstrip('/') for p in mutable]
    protected = [p.upper().rstrip('/') for p in protected]
    def matches(path, roots):
        return any(path == root or path.startswith(root + '/') for root in roots)
    def editable(path):
        return matches(path, mutable) and not matches(path, protected)
    errors, changed, categories = [], [], Counter()
    old, new = ReadOnlyImage(before), ReadOnlyImage(after)
    try:
        if len(old.data) != len(new.data) or old.data[:512] != new.data[:512]:
            raise ValueError('Image size or boot sector changed')
        old_tree, new_tree = inventory(old), inventory(new)
        # Родительские каталоги могут получать тестовые записи, но записи
        # остальных файлов и все их кластеры обязаны совпасть побайтно.
        containers = {'/'}
        for path in mutable:
            parts = path.strip('/').split('/')
            containers.update('/' + '/'.join(parts[:n]) for n in range(1, len(parts)))
        preserved = []
        for path, entry in old_tree.items():
            if editable(path):
                continue
            found = new_tree.get(path)
            fields = ('record', 'size') if path in containers else ('record', 'size', 'chain', 'sha256')
            if found is None or any(entry[k] != found[k] for k in fields):
                errors.append('Protected object changed: ' + path)
            preserved.append(dict(path=path, **entry))
        for path in new_tree.keys() - old_tree.keys():
            if not editable(path):
                errors.append('Unexpected new object: ' + path)
        allowed_clusters = set(old.cluster_chain(old.root_cluster) + new.cluster_chain(new.root_cluster))
        for tree in (old_tree, new_tree):
            for path, entry in tree.items():
                if editable(path) or path in containers:
                    allowed_clusters.update(entry['chain'])
        fsinfo = h.le16(old.data, 48)
        fs_sectors = {fsinfo, h.le16(old.data, 50) + fsinfo}
        for sector in range(len(old.data) // 512):
            offset = sector * 512
            a, b = old.data[offset:offset + 512], new.data[offset:offset + 512]
            if a == b:
                continue
            category = 'unexpected'
            if sector < old.reserved:
                if sector in fs_sectors and a[:488] == b[:488] and a[496:] == b[496:]:
                    category = 'FSInfo counters'
            elif sector < old.first_data_sector:
                fat, index = divmod(sector - old.reserved, old.fat_size)
                indices = [index * 128 + n for n in range(128) if a[n*4:n*4+4] != b[n*4:n*4+4]]
                if (old.mirrored or fat == old.active) and all(n in allowed_clusters for n in indices):
                    category = 'test FAT links'
            else:
                cluster = (sector - old.first_data_sector) // old.spc + 2
                if cluster in allowed_clusters:
                    category = 'test data/directories'
                elif old.get_fat(cluster) == 0 and new.get_fat(cluster) == 0:
                    # Временный файл/откат может оставить данные в свободном
                    # кластере. Он не принадлежал чужому файлу ни до, ни после.
                    category = 'free scratch before and after'
            categories[category] += 1
            changed.append(dict(sector=sector, category=category))
            if category == 'unexpected':
                errors.append(f'Unexpected sector change: {sector}')
        if old.mirrored:
            first = new.data[new.reserved*512:(new.reserved+new.fat_size)*512]
            for fat in range(1, new.fats):
                start = (new.reserved + fat * new.fat_size) * 512
                if new.data[start:start + new.fat_size*512] != first:
                    errors.append('FAT mirrors differ')
        return dict(passed=not errors, before_sha256=hashlib.sha256(old.data).hexdigest(),
                    after_sha256=hashlib.sha256(new.data).hexdigest(),
                    compared_sectors=len(old.data)//512, protected_objects=len(preserved),
                    protected=preserved, changed_sectors=changed, categories=dict(categories), errors=errors)
    finally:
        old.close()
        new.close()


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--before', type=Path, required=True)
    parser.add_argument('--after', type=Path, required=True)
    parser.add_argument('--mutable', action='append', default=[])
    parser.add_argument('--protected', action='append', default=[])
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    result = verify(args.before, args.after, args.mutable, args.protected)
    args.output.write_text(json.dumps(result, indent=2, ensure_ascii=False), encoding='utf-8')
    print(json.dumps({k: v for k, v in result.items() if k not in ('protected', 'changed_sectors')}, ensure_ascii=False))
    raise SystemExit(not result['passed'])
