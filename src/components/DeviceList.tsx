import React from 'react';
import {
  FlatList,
  TouchableOpacity,
  View,
  Text,
  StyleSheet,
  ListRenderItemInfo,
} from 'react-native';
import type { CastDevice } from '../hooks/useMirrorBridge';

interface Props {
  devices: CastDevice[];
  selectedDevice: CastDevice | null;
  onSelect: (device: CastDevice) => void;
}

export default function DeviceList({ devices, selectedDevice, onSelect }: Props): React.JSX.Element {
  if (devices.length === 0) {
    return (
      <View style={styles.empty}>
        <Text style={styles.emptyIcon}>📡</Text>
        <Text style={styles.emptyTitle}>No devices found</Text>
        <Text style={styles.emptyBody}>
          Make sure your Chromecast and iPhone are on the same Wi-Fi network.
        </Text>
      </View>
    );
  }

  function renderItem({ item }: ListRenderItemInfo<CastDevice>): React.JSX.Element {
    const selected = selectedDevice?.deviceId === item.deviceId;
    return (
      <TouchableOpacity
        style={[styles.row, selected && styles.rowSelected]}
        onPress={() => onSelect(item)}
        activeOpacity={0.7}
        accessibilityRole="button"
        accessibilityState={{ selected }}
      >
        <View style={styles.iconWrap}>
          <Text style={styles.iconText}>📺</Text>
        </View>
        <View style={styles.info}>
          <Text style={styles.name} numberOfLines={1}>{item.name}</Text>
          <Text style={styles.model} numberOfLines={1}>{item.modelName}</Text>
        </View>
        {selected && (
          <View style={styles.checkWrap}>
            <Text style={styles.checkText}>✓</Text>
          </View>
        )}
      </TouchableOpacity>
    );
  }

  return (
    <FlatList
      data={devices}
      keyExtractor={(item) => item.deviceId}
      renderItem={renderItem}
      style={styles.list}
      contentContainerStyle={styles.listContent}
      showsVerticalScrollIndicator={false}
    />
  );
}

const styles = StyleSheet.create({
  list: {
    flex: 1,
  },
  listContent: {
    gap: 10,
    paddingBottom: 16,
  },
  empty: {
    flex: 1,
    alignItems: 'center',
    justifyContent: 'center',
    paddingHorizontal: 24,
    paddingBottom: 60,
  },
  emptyIcon: {
    fontSize: 40,
    marginBottom: 16,
  },
  emptyTitle: {
    color: '#ffffff',
    fontSize: 17,
    fontWeight: '600',
    marginBottom: 8,
  },
  emptyBody: {
    color: '#ffffff',
    fontSize: 14,
    textAlign: 'center',
    lineHeight: 20,
  },
  row: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: '#000000',
    borderRadius: 14,
    padding: 16,
    borderWidth: 1.5,
    borderColor: 'transparent',
  },
  rowSelected: {
    borderColor: '#19FFA3',
  },
  iconWrap: {
    width: 42,
    height: 42,
    borderRadius: 10,
    backgroundColor: '#000000',
    alignItems: 'center',
    justifyContent: 'center',
    marginRight: 14,
  },
  iconText: {
    fontSize: 22,
  },
  info: {
    flex: 1,
  },
  name: {
    color: '#ffffff',
    fontSize: 15,
    fontWeight: '600',
  },
  model: {
    color: '#ffffff',
    fontSize: 12,
    marginTop: 2,
  },
  checkWrap: {
    width: 24,
    height: 24,
    borderRadius: 12,
    backgroundColor: '#19FFA3',
    alignItems: 'center',
    justifyContent: 'center',
    marginLeft: 10,
  },
  checkText: {
    color: '#ffffff',
    fontSize: 13,
    fontWeight: '700',
  },
});
