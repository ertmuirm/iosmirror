import { useCallback, useEffect, useRef, useState } from 'react';
import { NativeEventEmitter, NativeModules } from 'react-native';

const { MirrorBridge } = NativeModules;
const mirrorEmitter = new NativeEventEmitter(MirrorBridge);

export interface CastDevice {
  deviceId: string;
  name: string;
  modelName: string;
}

export type CastState = 'idle' | 'connecting' | 'mirroring' | 'disconnecting';

export function useMirrorBridge() {
  const [devices, setDevices] = useState<CastDevice[]>([]);
  const [scanning, setScanning] = useState(true);
  const [castState, setCastState] = useState<CastState>('idle');
  const [selectedDevice, setSelectedDevice] = useState<CastDevice | null>(null);
  const [debugLog, setDebugLog] = useState<string[]>([]);
  const subscriptions = useRef<ReturnType<typeof mirrorEmitter.addListener>[]>([]);

  useEffect(() => {
    subscriptions.current = [
      mirrorEmitter.addListener('onDevicesChanged', (updated: CastDevice[]) => {
        setDevices(updated);
        setScanning(false);
      }),
      mirrorEmitter.addListener('onCastStateChanged', ({ state }: { state: CastState }) => {
        setCastState(state);
      }),
      mirrorEmitter.addListener('onScanComplete', () => {
        setScanning(false);
      }),
      mirrorEmitter.addListener('onDebug', (msg: string) => {
        setDebugLog(prev => [...prev.slice(-9), msg]);
      }),
    ];

    MirrorBridge.startDiscovery();

    return () => {
      subscriptions.current.forEach(s => s.remove());
      MirrorBridge.stopDiscovery();
    };
  }, []);

  const selectDevice = useCallback((device: CastDevice) => {
    setSelectedDevice(device);
  }, []);

  const startMirror = useCallback(async () => {
    if (!selectedDevice) {
      throw new Error('No device selected');
    }
    setCastState('connecting');
    try {
      await MirrorBridge.startMirror(selectedDevice.deviceId);
    } catch (err) {
      setCastState('idle');
      throw err;
    }
  }, [selectedDevice]);

  const stopMirror = useCallback(async () => {
    setCastState('disconnecting');
    await MirrorBridge.stopMirror();
    setCastState('idle');
  }, []);

  return {
    devices,
    scanning,
    castState,
    selectedDevice,
    debugLog,
    selectDevice,
    startMirror,
    stopMirror,
  };
}
