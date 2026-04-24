import React, { useCallback } from 'react';
import {
  View,
  Text,
  TouchableOpacity,
  StyleSheet,
  ActivityIndicator,
  Alert,
} from 'react-native';
import DeviceList from '../components/DeviceList';
import { useMirrorBridge } from '../hooks/useMirrorBridge';

export default function HomeScreen(): React.JSX.Element {
  const {
    devices,
    scanning,
    castState,
    selectedDevice,
    selectDevice,
    startMirror,
    stopMirror,
  } = useMirrorBridge();

  const handleMirrorPress = useCallback(async () => {
    if (castState === 'mirroring') {
      await stopMirror();
    } else if (selectedDevice) {
      try {
        await startMirror();
      } catch (e: unknown) {
        Alert.alert('Connection failed', (e as Error).message ?? 'Unknown error');
      }
    }
  }, [castState, selectedDevice, startMirror, stopMirror]);

  const mirrorLabel =
    castState === 'mirroring'     ? 'Stop Mirroring' :
    castState === 'connecting'    ? 'Connecting…'    :
    castState === 'disconnecting' ? 'Stopping…'      :
                                    'Start Mirroring';

  const canPress = selectedDevice !== null &&
    castState !== 'connecting' &&
    castState !== 'disconnecting';

  return (
    <View style={styles.container}>
      {/* Header */}
      <View style={styles.header}>
        <Text style={styles.title}>Mirror</Text>
      </View>

      {/* Scan indicator */}
      {scanning && (
        <View style={styles.scanRow}>
          <ActivityIndicator size="small" color="#808080" />
          <Text style={styles.scanText}>Scanning for devices…</Text>
        </View>
      )}

      {/* Device list */}
      <DeviceList
        devices={devices}
        selectedDevice={selectedDevice}
        onSelect={selectDevice}
      />

      {/* Active cast badge */}
      {castState === 'mirroring' && selectedDevice && (
        <View style={styles.badge}>
          <View style={styles.badgeDot} />
          <Text style={styles.badgeText}>Mirroring to {selectedDevice.name}</Text>
        </View>
      )}

      {/* Start/stop button */}
      <TouchableOpacity
        style={[styles.button, !canPress && styles.buttonDisabled]}
        onPress={handleMirrorPress}
        disabled={!canPress}
        activeOpacity={0.8}
      >
        {(castState === 'connecting' || castState === 'disconnecting') ? (
          <ActivityIndicator color="#fff" />
        ) : (
          <Text style={styles.buttonText}>{mirrorLabel}</Text>
        )}
      </TouchableOpacity>

    </View>
  );
}

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#000000',
    paddingHorizontal: 24,
  },
  header: {
    paddingTop: 32,
    marginBottom: 28,
  },
  title: {
    fontSize: 34,
    fontWeight: '700',
    color: '#ffffff',
    letterSpacing: 0.3,
  },
  scanRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 10,
    marginBottom: 16,
  },
  scanText: {
    color: '#ffffff',
    fontSize: 13,
  },
  badge: {
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: '#000000',
    borderRadius: 12,
    paddingHorizontal: 16,
    paddingVertical: 14,
    marginBottom: 16,
    gap: 10,
  },
  badgeDot: {
    width: 8,
    height: 8,
    borderRadius: 4,
    backgroundColor: '#808080',
  },
  badgeText: {
    color: '#ffffff',
    fontSize: 14,
  },
  button: {
    backgroundColor: '#808080',
    borderRadius: 16,
    paddingVertical: 18,
    alignItems: 'center',
    justifyContent: 'center',
    marginBottom: 14,
    minHeight: 56,
  },
  buttonDisabled: {
    backgroundColor: '#000000',
  },
  buttonText: {
    color: '#ffffff',
    fontSize: 17,
    fontWeight: '600',
    letterSpacing: 0.2,
  },
});
