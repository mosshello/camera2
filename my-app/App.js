import { useCallback, useEffect, useState } from 'react';
import {
  ActivityIndicator,
  Alert,
  AsyncStorage,
  Image,
  NativeEventEmitter,
  NativeModules,
  Platform,
  Pressable,
  requireNativeComponent,
  StyleSheet,
  Text,
  View,
} from 'react-native';
import { StatusBar } from 'expo-status-bar';
import * as MediaLibrary from 'expo-media-library';

const CAMERA_MODE = {
  BACK: 'back',
  FRONT: 'front',
  PIP_SQUARE: 'pip_square',
  PIP_CIRCLE: 'pip_circle',
  LR: 'lr',
  SX: 'sx',
};

const LAYOUT_MAP = {
  [CAMERA_MODE.BACK]: 'back',
  [CAMERA_MODE.FRONT]: 'front',
  [CAMERA_MODE.PIP_SQUARE]: 'pip_square',
  [CAMERA_MODE.PIP_CIRCLE]: 'pip_circle',
  [CAMERA_MODE.LR]: 'lr',
  [CAMERA_MODE.SX]: 'sx',
};

let NativeDualCameraView;
try {
  NativeDualCameraView = requireNativeComponent('DualCameraView');
} catch (e) {
  NativeDualCameraView = null;
}

const { DualCameraModule, DualCameraEventEmitter, CameraPermissionModule } = NativeModules;

let eventEmitter = null;
if (DualCameraEventEmitter) {
  eventEmitter = new NativeEventEmitter(DualCameraEventEmitter);
}

export default function App() {
  const [cameraMode, setCameraMode] = useState(CAMERA_MODE.BACK);
  const { width: screenWidth, height: screenHeight } = require('react-native').Dimensions.get('window');
  const [captureMode, setCaptureMode] = useState('picture');
  const [saving, setSaving] = useState(false);
  const [recording, setRecording] = useState(false);
  const [cameraStatus, setCameraStatus] = useState('loading');
  const [audioLevel, setAudioLevel] = useState(0);
  const [mediaPermission, requestMediaPermission] = MediaLibrary.usePermissions({
    writeOnly: true,
    granularPermissions: ['photo'],
  });
  // Layout adjustment state
  const [dualLayoutRatio, setDualLayoutRatio] = useState(0.5);
  const [pipSize, setPipSize] = useState(0.28);
  const [pipPosition, setPipPosition] = useState({ x: 0.85, y: 0.80 });
  const [frontZoom, setFrontZoom] = useState(1.0);
  const [backZoom, setBackZoom] = useState(1.0);
  const [showAdjustment, setShowAdjustment] = useState(false);
  const [saveAspectRatio, setSaveAspectRatio] = useState('9:16');
  // Flip state: true = front swapped with back (layout-dependent)
  const [isFlipped, setIsFlipped] = useState(false);
  // LR/SX zoom target: 'primary' = main area camera (back), 'secondary' = other camera (front)
  const [activeZoomTarget, setActiveZoomTarget] = useState('primary');

  // 检查相机权限
  useEffect(() => {
    let cancelled = false;
    (async () => {
      if (!CameraPermissionModule) {
        setCameraStatus('unavailable');
        return;
      }
      try {
        const status = await CameraPermissionModule.getCameraAuthorizationStatus();
        if (cancelled) return;
        if (status === 'authorized') {
          setCameraStatus('authorized');
        } else if (status === 'not_determined') {
          setCameraStatus('not_determined');
        } else {
          setCameraStatus('denied');
        }
      } catch (e) {
        if (!cancelled) setCameraStatus('unavailable');
      }
    })();
    return () => { cancelled = true; };
  }, []);

  // Load saved aspect ratio on mount
  useEffect(() => {
    (async () => {
      try {
        const saved = await AsyncStorage.getItem('dualcam_save_aspect');
        if (saved && ['9:16', '3:4', '1:1'].includes(saved)) {
          setSaveAspectRatio(saved);
        }
      } catch (_) {}
    })();
  }, []);

  const ensureMediaPermission = useCallback(async () => {
    if (mediaPermission?.granted) return true;
    const result = await requestMediaPermission();
    return result.granted ? true : (Alert.alert('需要相册权限', '保存照片需要相册授权。'), false);
  }, [mediaPermission?.granted, requestMediaPermission]);

  useEffect(() => {
    if (!eventEmitter) return;

    const subPhotoSaved = eventEmitter.addListener('onPhotoSaved', async (event) => {
      setSaving(false);
      try {
        const ok = await ensureMediaPermission();
        if (ok) {
          await MediaLibrary.saveToLibraryAsync(event.uri);
          Alert.alert('已保存', '照片已保存到相册');
        }
      } catch (e) {
        Alert.alert('保存失败', e?.message ?? String(e));
      }
    });

    const subPhotoError = eventEmitter.addListener('onPhotoError', (event) => {
      setSaving(false);
      Alert.alert('拍照失败', event.error ?? '未知错误');
    });

    const subRecordingFinished = eventEmitter.addListener('onRecordingFinished', async (event) => {
      setRecording(false);
      try {
        const ok = await ensureMediaPermission();
        if (ok) {
          await MediaLibrary.saveToLibraryAsync(event.uri);
          Alert.alert('已保存', '视频已保存到相册');
        }
      } catch (e) {
        Alert.alert('保存失败', e?.message ?? String(e));
      }
    });

    const subRecordingError = eventEmitter.addListener('onRecordingError', (event) => {
      setRecording(false);
      Alert.alert('录制失败', event.error ?? '未知错误');
    });

    const subSessionError = eventEmitter.addListener('onSessionError', (event) => {
      setSaving(false);
      setRecording(false);
      Alert.alert('相机错误', event.error ?? '相机会话启动失败');
    });

    const subAudioLevel = eventEmitter.addListener('onAudioLevel', (event) => {
      setAudioLevel(event.average ?? 0);
    });

    const subPipPositionChanged = eventEmitter.addListener('onPipPositionChanged', (event) => {
      setPipPosition({ x: event.x ?? 0.85, y: event.y ?? 0.80 });
    });

    const subPipSizeChanged = eventEmitter.addListener('onPipSizeChanged', (event) => {
      setPipSize(event.size ?? 0.28);
    });

    return () => {
      subPhotoSaved.remove();
      subPhotoError.remove();
      subRecordingFinished.remove();
      subRecordingError.remove();
      subSessionError.remove();
      subAudioLevel.remove();
      subPipPositionChanged.remove();
      subPipSizeChanged.remove();
    };
  }, [ensureMediaPermission]);

  // 权限批准后启动原生会话 + 音频监测
  useEffect(() => {
    if (cameraStatus === 'authorized' && DualCameraModule?.startSession) {
      DualCameraModule.startSession();
      DualCameraModule.startAudioMetering();
    }
    return () => {
      if (DualCameraModule?.stopAudioMetering) {
        DualCameraModule.stopAudioMetering();
      }
      if (DualCameraModule?.stopSession) {
        DualCameraModule.stopSession();
      }
    };
  }, [cameraStatus]);

  const requestCamera = useCallback(async () => {
    if (!CameraPermissionModule?.requestCameraPermission) return;
    try {
      const granted = await CameraPermissionModule.requestCameraPermission();
      setCameraStatus(granted ? 'authorized' : 'denied');
    } catch (e) {
      setCameraStatus('denied');
    }
  }, []);

  const takePhoto = useCallback(async () => {
    if (!DualCameraModule?.takePhoto) { Alert.alert('错误', '原生模块不可用'); return; }
    const ok = await ensureMediaPermission();
    if (!ok) return;
    setSaving(true);
    DualCameraModule.takePhoto();
  }, [ensureMediaPermission]);

  const startRecording = useCallback(() => {
    if (!DualCameraModule?.startRecording) { Alert.alert('错误', '原生模块不可用'); return; }
    setRecording(true);
    DualCameraModule.startRecording();
  }, []);

  const stopRecording = useCallback(() => {
    if (!DualCameraModule?.stopRecording) return;
    DualCameraModule.stopRecording();
  }, []);

  const handleShutterPress = useCallback(() => {
    if (recording) {
      stopRecording();
    } else if (captureMode === 'picture') {
      takePhoto();
    } else {
      startRecording();
    }
  }, [recording, captureMode, takePhoto, startRecording, stopRecording]);

  const handleFlip = useCallback(() => {
    if (!DualCameraModule?.flipCamera) return;
    DualCameraModule.flipCamera();
    setIsFlipped(v => !v);
  }, []);

  const effectiveCamera = (() => {
    if (cameraMode === CAMERA_MODE.BACK) return 'back';
    if (cameraMode === CAMERA_MODE.FRONT) return 'front';
    // LR/SX: camera controlled by activeZoomTarget
    if (cameraMode === CAMERA_MODE.LR || cameraMode === CAMERA_MODE.SX) {
      return activeZoomTarget === 'primary' ? 'back' : 'front';
    }
    // PiP: controls the small window camera (not the main view)
    // pipMainIsBack=!isFlipped, small window is the camera that is NOT the main view
    return isFlipped ? 'back' : 'front';
  })();

  const effectiveZoomLevels = effectiveCamera === 'back' ? [0.5, 1.0, 2.0, 3.0, 5.0] : [1.0, 2.0];

  const handleModeSwitch = useCallback((mode) => {
    setCameraMode(mode);
    setDualLayoutRatio(0.5);
    setPipSize(0.28);
    setPipPosition({ x: 0.85, y: 0.80 });
    setActiveZoomTarget('primary');
    setShowAdjustment(false);
    setIsFlipped(false);
  }, []);

  // 加载中
  if (cameraStatus === 'loading') {
    return (
      <View style={styles.centered}>
        <ActivityIndicator size="large" color="#fff" />
        <StatusBar style="light" />
      </View>
    );
  }

  // 相机未授权
  if (cameraStatus === 'not_determined') {
    return (
      <View style={styles.centered}>
        <Text style={styles.permissionTitle}>需要相机权限</Text>
        <Text style={styles.permissionBody}>双摄相机需要访问前置和后置摄像头</Text>
        <Pressable style={styles.primaryButton} onPress={requestCamera}>
          <Text style={styles.primaryButtonLabel}>授权相机</Text>
        </Pressable>
        <StatusBar style="light" />
      </View>
    );
  }

  // 权限拒绝 / 模块不可用
  if (cameraStatus === 'denied' || cameraStatus === 'unavailable') {
    return (
      <View style={styles.centered}>
        <Text style={styles.permissionTitle}>无法使用相机</Text>
        <Text style={styles.permissionBody}>
          {cameraStatus === 'denied' ? '请在系统设置中开启相机权限' : '原生模块未加载，请重新构建'}
        </Text>
        <StatusBar style="light" />
      </View>
    );
  }

  // 正常渲染
  return (
    <View style={styles.root}>
      {NativeDualCameraView ? (
        <NativeDualCameraView
          style={styles.nativeCamera}
          layoutMode={LAYOUT_MAP[cameraMode]}
          saveAspectRatio={saveAspectRatio}
          dualLayoutRatio={cameraMode === CAMERA_MODE.LR || cameraMode === CAMERA_MODE.SX ? dualLayoutRatio : 0.5}
          pipSize={cameraMode === CAMERA_MODE.PIP_SQUARE || cameraMode === CAMERA_MODE.PIP_CIRCLE ? pipSize : 0.28}
          pipPositionX={pipPosition.x}
          pipPositionY={pipPosition.y}
          sxBackOnTop={cameraMode === CAMERA_MODE.LR || cameraMode === CAMERA_MODE.SX ? !isFlipped : true}
          pipMainIsBack={cameraMode === CAMERA_MODE.PIP_SQUARE || cameraMode === CAMERA_MODE.PIP_CIRCLE ? !isFlipped : true}
        />
      ) : (
        <View style={styles.fallbackContainer}>
          <Text style={styles.fallbackTitle}>双摄相机</Text>
          <Text style={styles.fallbackText}>原生模块加载中...</Text>
        </View>
      )}

      <BottomBar
        cameraMode={cameraMode}
        captureMode={captureMode}
        recording={recording}
        saving={saving}
        onShutterPress={handleShutterPress}
        onModeSwitch={handleModeSwitch}
        onCaptureModeChange={(m) => { if (!recording) setCaptureMode(m); }}
        isFlipped={isFlipped}
        onFlip={handleFlip}
      />

      {/* Zoom bar — shown for all modes when not recording */}
      {!recording ? (
        <View style={styles.zoomBarContainer} pointerEvents="box-none">
          {/* LR/SX: top bar with camera switch button */}
          {(cameraMode === CAMERA_MODE.LR || cameraMode === CAMERA_MODE.SX) ? (
            <View style={styles.zoomBarTopRow}>
              {/* Camera switch button */}
              <Pressable
                style={styles.cameraSwitchBtn}
                onPress={() => setActiveZoomTarget(v => v === 'primary' ? 'secondary' : 'primary')}
              >
                <Text style={styles.cameraSwitchBtnText}>
                  {activeZoomTarget === 'primary' ? '后置▼' : '前置▼'}
                </Text>
              </Pressable>
              {/* Zoom level buttons */}
              {effectiveZoomLevels.map(level => {
                const active = effectiveCamera === 'back' ? backZoom : frontZoom;
                return (
                  <Pressable
                    key={level}
                    style={[styles.zoomBtn, active === level && styles.zoomBtnActive]}
                    onPress={() => {
                      if (DualCameraModule?.setZoom) {
                        DualCameraModule.setZoom(effectiveCamera, level);
                      }
                      if (effectiveCamera === 'back') setBackZoom(level);
                      else setFrontZoom(level);
                    }}
                  >
                    <Text style={[styles.zoomBtnText, active === level && styles.zoomBtnTextActive]}>
                      {level}x
                    </Text>
                  </Pressable>
                );
              })}
            </View>
          ) : null}

          {/* Single mode: top bar (no camera switch button) */}
          {(cameraMode === CAMERA_MODE.BACK || cameraMode === CAMERA_MODE.FRONT) ? (
            <View style={styles.zoomBarTopRow}>
              {effectiveZoomLevels.map(level => {
                const active = effectiveCamera === 'back' ? backZoom : frontZoom;
                return (
                  <Pressable
                    key={level}
                    style={[styles.zoomBtn, active === level && styles.zoomBtnActive]}
                    onPress={() => {
                      if (DualCameraModule?.setZoom) {
                        DualCameraModule.setZoom(effectiveCamera, level);
                      }
                      if (effectiveCamera === 'back') setBackZoom(level);
                      else setFrontZoom(level);
                    }}
                  >
                    <Text style={[styles.zoomBtnText, active === level && styles.zoomBtnTextActive]}>
                      {level}x
                    </Text>
                  </Pressable>
                );
              })}
            </View>
          ) : null}

          {/* PiP mode: zoom bar follows small window (vertical, on the left side) */}
          {(cameraMode === CAMERA_MODE.PIP_SQUARE || cameraMode === CAMERA_MODE.PIP_CIRCLE) ? (() => {
            const pipW = pipSize * screenWidth;
            const pipH = pipSize * screenHeight;
            const pipCenterX = pipPosition.x * screenWidth;
            const pipCenterY = pipPosition.y * screenHeight;
            const barW = 44;
            const barH = effectiveZoomLevels.length * 44;
            const rawBarLeft = pipCenterX - pipW / 2 - 8 - barW;
            const clampedBarLeft = Math.max(0, Math.min(screenWidth - barW, rawBarLeft));
            const rawBarTop = pipCenterY - barH / 2;
            const clampedBarTop = Math.max(0, Math.min(screenHeight - barH, rawBarTop));
            const active = effectiveCamera === 'back' ? backZoom : frontZoom;
            return (
              <View style={[styles.zoomBarPip, {
                left: clampedBarLeft,
                top: clampedBarTop,
              }]} pointerEvents="box-none">
                {effectiveZoomLevels.map(level => (
                  <Pressable
                    key={level}
                    style={[styles.zoomBtnPip, active === level && styles.zoomBtnActive]}
                    onPress={() => {
                      if (DualCameraModule?.setZoom) {
                        DualCameraModule.setZoom(effectiveCamera, level);
                      }
                      if (effectiveCamera === 'back') setBackZoom(level);
                      else setFrontZoom(level);
                    }}
                  >
                    <Text style={[styles.zoomBtnText, active === level && styles.zoomBtnTextActive]}>
                      {level}x
                    </Text>
                  </Pressable>
                ))}
              </View>
            );
          })() : null}
        </View>
      ) : null}

      {!mediaPermission?.granted ? (
        <View style={styles.mediaBanner}>
          <Text style={styles.mediaBannerText}>保存需要相册权限</Text>
          <Pressable style={styles.secondaryButton} onPress={requestMediaPermission}>
            <Text style={styles.secondaryButtonLabel}>去授权</Text>
          </Pressable>
        </View>
      ) : null}

      {saving ? (
        <View style={styles.savingOverlay} pointerEvents="none">
          <ActivityIndicator size="large" color="#fff" />
        </View>
      ) : null}

      {recording ? (
        <View style={styles.recordingIndicator} pointerEvents="none">
          <View style={styles.recordingDot} />
          <Text style={styles.recordingText}>录制中</Text>
        </View>
      ) : null}

      {recording && audioLevel > 0.05 ? (
        <AudioLevelIndicator level={audioLevel} />
      ) : null}

      {/* 布局调整面板 */}
      {showAdjustment && (cameraMode === CAMERA_MODE.LR || cameraMode === CAMERA_MODE.SX) ? (
        <View style={styles.adjustmentPanel} pointerEvents="box-none">
          <Text style={styles.adjustmentTitle}>左右比例</Text>
          <View style={styles.sliderRow}>
            <Text style={styles.sliderLabel}>前</Text>
            <View style={styles.sliderTrack}>
              <View style={[styles.sliderFill, { flex: dualLayoutRatio }]} />
            </View>
            <Text style={styles.sliderLabel}>后</Text>
          </View>
          <Text style={styles.adjustmentValue}>{Math.round(dualLayoutRatio * 100)}% : {Math.round((1 - dualLayoutRatio) * 100)}%</Text>
          <View style={{ flexDirection: 'row', justifyContent: 'space-between', marginTop: 6, gap: 4 }}>
            <Pressable style={styles.adjustBtn} onPress={() => setDualLayoutRatio(v => Math.max(0.1, +(v - 0.05).toFixed(2)))}>
              <Text style={styles.adjustBtnText}>前+</Text>
            </Pressable>
            <Pressable style={styles.adjustBtn} onPress={() => setDualLayoutRatio(v => Math.min(0.9, +(v + 0.05).toFixed(2)))}>
              <Text style={styles.adjustBtnText}>后+</Text>
            </Pressable>
          </View>
        </View>
      ) : null}

      {showAdjustment && (cameraMode === CAMERA_MODE.PIP_SQUARE || cameraMode === CAMERA_MODE.PIP_CIRCLE) ? (
        <View style={styles.adjustmentPanel} pointerEvents="box-none">
          <Text style={styles.adjustmentTitle}>画中画</Text>
          <View style={styles.sliderRow}>
            <Text style={styles.sliderLabel}>小</Text>
            <View style={styles.sliderTrack}>
              <View style={[styles.sliderFill, { flex: pipSize / 0.5 }]} />
            </View>
            <Text style={styles.sliderLabel}>大</Text>
          </View>
          <Text style={styles.adjustmentValue}>大小: {Math.round(pipSize * 100)}%</Text>
          <View style={{ flexDirection: 'row', justifyContent: 'space-between', marginTop: 6, gap: 4 }}>
            <Pressable style={styles.adjustBtn} onPress={() => setPipPosition({ x: 0.85, y: 0.80 })}>
              <Text style={styles.adjustBtnText}>右下</Text>
            </Pressable>
            <Pressable style={styles.adjustBtn} onPress={() => setPipPosition({ x: 0.5, y: 0.5 })}>
              <Text style={styles.adjustBtnText}>居中</Text>
            </Pressable>
          </View>
        </View>
      ) : null}

      {/* Save aspect ratio picker — shown on all modes */}
      {!recording && !saving ? (
        <View style={styles.aspectPickerContainer} pointerEvents="box-none">
          {['9:16', '3:4', '1:1'].map(r => (
            <Pressable
              key={r}
              style={[styles.aspectBtn, saveAspectRatio === r && styles.aspectBtnActive]}
              onPress={async () => {
                setSaveAspectRatio(r);
                try { await AsyncStorage.setItem('dualcam_save_aspect', r); } catch (_) {}
              }}
            >
              <Text style={[styles.aspectBtnText, saveAspectRatio === r && styles.aspectBtnTextActive]}>{r}</Text>
            </Pressable>
          ))}
        </View>
      ) : null}

      {/* 调整按钮 */}
      {(cameraMode === CAMERA_MODE.LR || cameraMode === CAMERA_MODE.SX || cameraMode === CAMERA_MODE.PIP_SQUARE || cameraMode === CAMERA_MODE.PIP_CIRCLE) && !recording ? (
        <Pressable style={styles.adjustToggleBtn} onPress={() => setShowAdjustment(v => !v)}>
          <Text style={styles.adjustToggleText}>{showAdjustment ? '完成' : '调整'}</Text>
        </Pressable>
      ) : null}

      <StatusBar style="light" />
    </View>
  );
}

function BottomBar({ cameraMode, captureMode, recording, saving, onShutterPress, onModeSwitch, onCaptureModeChange, isFlipped, onFlip }) {
  return (
    <>
      <View style={styles.rightPanel} pointerEvents="box-none">
        <ModeButton selected={cameraMode === CAMERA_MODE.BACK} onPress={() => onModeSwitch(CAMERA_MODE.BACK)} label="后" />
        <ModeButton selected={cameraMode === CAMERA_MODE.FRONT} onPress={() => onModeSwitch(CAMERA_MODE.FRONT)} label="前" />
        <ModeButton selected={cameraMode === CAMERA_MODE.PIP_SQUARE} onPress={() => onModeSwitch(CAMERA_MODE.PIP_SQUARE)} label="方" />
        <ModeButton selected={cameraMode === CAMERA_MODE.PIP_CIRCLE} onPress={() => onModeSwitch(CAMERA_MODE.PIP_CIRCLE)} label="圆" />
        <ModeButton selected={cameraMode === CAMERA_MODE.LR} onPress={() => onModeSwitch(CAMERA_MODE.LR)} label="左" />
        <ModeButton selected={cameraMode === CAMERA_MODE.SX} onPress={() => onModeSwitch(CAMERA_MODE.SX)} label="上" />
      </View>

      <View style={styles.bottomBar} pointerEvents="box-none">
        <View style={styles.modeToggle}>
          <Pressable style={[styles.modeBtn, captureMode === 'picture' && styles.modeBtnActive]} onPress={() => onCaptureModeChange('picture')}>
            <Text style={[styles.modeBtnText, captureMode === 'picture' && styles.modeBtnTextActive]}>拍照</Text>
          </Pressable>
          <Pressable style={[styles.modeBtn, captureMode === 'video' && styles.modeBtnActive]} onPress={() => onCaptureModeChange('video')}>
            <Text style={[styles.modeBtnText, captureMode === 'video' && styles.modeBtnTextActive]}>视频</Text>
          </Pressable>
        </View>

        <Pressable
          accessibilityRole="button"
          accessibilityLabel={recording ? "停止" : (captureMode === 'picture' ? "拍照" : "录制")}
          style={({ pressed }) => [
            styles.shutterOuter,
            pressed && styles.shutterOuterMuted,
            saving && styles.shutterOuterMuted,
            recording && styles.shutterOuterRecording,
          ]}
          onPress={onShutterPress}
        >
          <View style={[styles.shutterInner, recording && styles.shutterInnerRecording]} />
        </Pressable>

        <Pressable
          style={[styles.flipBtn, isFlipped && styles.flipBtnActive]}
          onPress={onFlip}
          accessibilityRole="button"
          accessibilityLabel="翻转镜头"
        >
          <Text style={styles.flipBtnText}>⟳</Text>
        </Pressable>
      </View>
    </>
  );
}

function ModeButton({ selected, onPress, label }) {
  return (
    <Pressable style={[styles.modeButton, selected && styles.modeButtonSelected]} onPress={onPress}>
      <Text style={[styles.modeLabel, selected && styles.modeLabelSelected]}>{label}</Text>
    </Pressable>
  );
}

function AudioLevelIndicator({ level }) {
  const barCount = 12;
  const activeCount = Math.round(level * barCount);

  return (
    <View style={styles.audioIndicator} pointerEvents="none">
      <Text style={styles.audioLabel}>音频</Text>
      <View style={styles.audioBars}>
        {Array.from({ length: barCount }).map((_, i) => (
          <View
            key={i}
            style={[
              styles.audioBar,
              i < activeCount ? styles.audioBarActive : null,
            ]}
          />
        ))}
      </View>
    </View>
  );
}

const styles = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#000' },
  nativeCamera: { flex: 1 },

  fallbackContainer: { flex: 1, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 32 },
  fallbackTitle: { color: '#fff', fontSize: 28, fontWeight: '700', marginBottom: 12 },
  fallbackText: { color: 'rgba(255,255,255,0.7)', fontSize: 15, textAlign: 'center' },

  rightPanel: {
    position: 'absolute', right: 0, top: 0, bottom: 0,
    justifyContent: 'center', alignItems: 'center',
    paddingVertical: 60, gap: 16,
  },
  modeButton: {
    width: 52, height: 52, borderRadius: 12,
    backgroundColor: 'rgba(0,0,0,0.45)',
    alignItems: 'center', justifyContent: 'center',
    borderWidth: 2, borderColor: 'transparent',
  },
  modeButtonSelected: { borderColor: '#4da6ff', backgroundColor: 'rgba(77,166,255,0.25)' },
  modeLabel: { color: '#ccc', fontSize: 13, fontWeight: '600' },
  modeLabelSelected: { color: '#4da6ff', fontWeight: '700' },

  bottomBar: {
    position: 'absolute', left: 0, right: 0, bottom: 0,
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-around',
    paddingBottom: Platform.OS === 'ios' ? 44 : 32, paddingTop: 16, paddingHorizontal: 20,
  },
  modeToggle: {
    flexDirection: 'row', backgroundColor: 'rgba(0,0,0,0.5)',
    borderRadius: 20, padding: 4, width: 100,
  },
  modeBtn: { flex: 1, paddingVertical: 6, alignItems: 'center', borderRadius: 16 },
  modeBtnActive: { backgroundColor: 'rgba(255,255,255,0.25)' },
  modeBtnText: { color: '#aaa', fontSize: 13, fontWeight: '500' },
  modeBtnTextActive: { color: '#fff', fontWeight: '700' },
  shutterOuter: {
    width: 72, height: 72, borderRadius: 36, borderWidth: 4, borderColor: '#fff',
    alignItems: 'center', justifyContent: 'center',
  },
  shutterOuterMuted: { opacity: 0.5 },
  shutterOuterRecording: { borderColor: '#ff4444' },
  shutterInner: { width: 58, height: 58, borderRadius: 29, backgroundColor: '#fff' },
  shutterInnerRecording: { width: 28, height: 28, borderRadius: 6, backgroundColor: '#ff4444' },
  flipBtn: {
    width: 52, height: 52, borderRadius: 26,
    backgroundColor: 'rgba(0,0,0,0.45)',
    alignItems: 'center', justifyContent: 'center',
    borderWidth: 2, borderColor: 'transparent',
  },
  flipBtnActive: { borderColor: '#4da6ff', backgroundColor: 'rgba(77,166,255,0.25)' },
  flipBtnText: { color: '#ccc', fontSize: 24, fontWeight: '700' },

  mediaBanner: {
    position: 'absolute', left: 16, right: 16,
    bottom: Platform.OS === 'ios' ? 140 : 130,
    flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between',
    gap: 12, paddingHorizontal: 14, paddingVertical: 10, borderRadius: 12,
    backgroundColor: 'rgba(0,0,0,0.55)',
  },
  mediaBannerText: { flex: 1, color: '#fff', fontSize: 13 },
  secondaryButton: {
    paddingHorizontal: 12, paddingVertical: 6, borderRadius: 999, backgroundColor: '#fff',
  },
  secondaryButtonLabel: { color: '#000', fontSize: 13, fontWeight: '600' },
  savingOverlay: {
    ...StyleSheet.absoluteFillObject, alignItems: 'center', justifyContent: 'center',
    backgroundColor: 'rgba(0,0,0,0.25)',
  },
  recordingIndicator: {
    position: 'absolute', top: Platform.OS === 'ios' ? 60 : 44, alignSelf: 'center',
    flexDirection: 'row', alignItems: 'center',
    backgroundColor: 'rgba(0,0,0,0.6)', paddingHorizontal: 14, paddingVertical: 6,
    borderRadius: 16, gap: 6,
  },
  recordingDot: { width: 8, height: 8, borderRadius: 4, backgroundColor: '#ff4444' },
  recordingText: { color: '#fff', fontSize: 13, fontWeight: '600' },

  audioIndicator: {
    position: 'absolute',
    top: Platform.OS === 'ios' ? 60 : 44,
    left: 16,
    flexDirection: 'row',
    alignItems: 'center',
    backgroundColor: 'rgba(0,0,0,0.55)',
    paddingHorizontal: 10,
    paddingVertical: 6,
    borderRadius: 12,
    gap: 6,
  },
  audioLabel: { color: '#aaa', fontSize: 11, fontWeight: '600' },
  audioBars: { flexDirection: 'row', alignItems: 'flex-end', gap: 2, height: 16 },
  audioBar: {
    width: 3,
    height: 4,
    borderRadius: 1.5,
    backgroundColor: 'rgba(255,255,255,0.2)',
  },
  audioBarActive: { backgroundColor: '#4dff4d' },

  centered: { flex: 1, backgroundColor: '#000', alignItems: 'center', justifyContent: 'center', paddingHorizontal: 24 },
  permissionTitle: { color: '#fff', fontSize: 20, fontWeight: '700', marginBottom: 8, textAlign: 'center' },
  permissionBody: { color: 'rgba(255,255,255,0.75)', fontSize: 15, textAlign: 'center', marginBottom: 20, lineHeight: 22 },
  primaryButton: { paddingHorizontal: 18, paddingVertical: 12, borderRadius: 999, backgroundColor: '#fff' },
  primaryButtonLabel: { color: '#000', fontSize: 16, fontWeight: '600' },

  adjustmentPanel: {
    position: 'absolute', left: 12, top: 80,
    width: 180, backgroundColor: 'rgba(0,0,0,0.7)',
    borderRadius: 12, padding: 12,
  },
  adjustmentTitle: { color: '#fff', fontSize: 13, fontWeight: '700', marginBottom: 8 },
  sliderRow: { flexDirection: 'row', alignItems: 'center', gap: 8 },
  sliderLabel: { color: '#aaa', fontSize: 11, width: 16, textAlign: 'center' },
  sliderTrack: {
    flex: 1, height: 4, backgroundColor: 'rgba(255,255,255,0.2)',
    borderRadius: 2, position: 'relative',
  },
  sliderFill: { backgroundColor: '#4da6ff', borderRadius: 2, position: 'absolute', left: 0, top: 0, bottom: 0 },
  sliderThumb: {
    position: 'absolute', top: -5,
    width: 14, height: 14, borderRadius: 7,
    backgroundColor: '#fff', borderWidth: 2, borderColor: '#4da6ff',
  },
  adjustmentValue: { color: '#4da6ff', fontSize: 12, marginTop: 6, fontWeight: '600' },
  adjustBtn: {
    marginTop: 8, paddingVertical: 4, paddingHorizontal: 10,
    backgroundColor: 'rgba(77,166,255,0.3)', borderRadius: 6, alignItems: 'center',
  },
  adjustBtnText: { color: '#4da6ff', fontSize: 12, fontWeight: '600' },
  adjustToggleBtn: {
    position: 'absolute', left: 12, top: 60,
    paddingHorizontal: 12, paddingVertical: 6,
    backgroundColor: 'rgba(0,0,0,0.5)', borderRadius: 12,
    borderWidth: 1, borderColor: 'rgba(255,255,255,0.2)',
  },
  adjustToggleText: { color: '#fff', fontSize: 13, fontWeight: '600' },

  aspectPickerContainer: {
    position: 'absolute', left: 12, top: 60,
    flexDirection: 'row', gap: 6,
  },
  aspectBtn: {
    paddingHorizontal: 10, paddingVertical: 5,
    backgroundColor: 'rgba(0,0,0,0.5)',
    borderRadius: 10,
    borderWidth: 1, borderColor: 'rgba(255,255,255,0.2)',
  },
  aspectBtnActive: {
    backgroundColor: 'rgba(77,166,255,0.7)',
    borderColor: '#4da6ff',
  },
  aspectBtnText: { color: 'rgba(255,255,255,0.6)', fontSize: 12, fontWeight: '600' },
  aspectBtnTextActive: { color: '#fff' },

  // Zoom bar
  zoomBarContainer: {
    position: 'absolute',
    top: Platform.OS === 'ios' ? 60 : 44,
    left: 0, right: 0,
    flexDirection: 'row',
    alignItems: 'center',
    gap: 8,
    pointerEvents: 'box-none',
  },
  zoomBarTopRow: {
    flexDirection: 'row',
    alignItems: 'center',
    gap: 6,
    marginLeft: 12,
  },
  cameraSwitchBtn: {
    paddingHorizontal: 10, paddingVertical: 6,
    backgroundColor: 'rgba(0,0,0,0.45)',
    borderRadius: 12,
    borderWidth: 1, borderColor: 'rgba(255,255,255,0.2)',
  },
  cameraSwitchBtnText: {
    color: 'rgba(255,255,255,0.85)', fontSize: 12, fontWeight: '600',
  },
  zoomBarPip: {
    position: 'absolute',
    width: 44,
    flexDirection: 'column',
    alignItems: 'center',
    gap: 4,
  },
  zoomBtn: {
    paddingHorizontal: 12, paddingVertical: 6,
    backgroundColor: 'rgba(0,0,0,0.45)',
    borderRadius: 14,
    borderWidth: 1, borderColor: 'rgba(255,255,255,0.2)',
    minWidth: 44, alignItems: 'center',
  },
  zoomBtnPip: {
    width: 44, paddingVertical: 6,
    backgroundColor: 'rgba(0,0,0,0.45)',
    borderRadius: 8,
    borderWidth: 1, borderColor: 'rgba(255,255,255,0.2)',
    alignItems: 'center',
  },
  zoomBtnActive: {
    backgroundColor: 'rgba(77,166,255,0.7)',
    borderColor: '#4da6ff',
  },
  zoomBtnText: { color: 'rgba(255,255,255,0.7)', fontSize: 13, fontWeight: '600' },
  zoomBtnTextActive: { color: '#fff', fontWeight: '700' },
  zoomBar: {}, // kept for backward compat, no longer used
});
