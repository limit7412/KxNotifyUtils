module SteamVR
  # openvr_api.dll の最小バインディング（仕様書 4.6 節）。
  #
  # openvr_api.dll は同梱せず、SteamVR がインストールしたものを実行時に探して動的ロードする。
  # そのため lib 宣言は動的ロードの 3 関数だけで、OpenVR 側の関数は GetProcAddress で解決する。
  # この宣言を参照するのは同じコンテキストの openvr_repository.cr だけとする。
  #
  # FnTable の構造体は openvr_capi.h から機械的に写したものである。
  # 呼ぶ関数だけを型付きの Proc へ変換して使うため、要素はすべて関数ポインタとして宣言する。
  # 並び順そのものが ABI であり、要素を 1 つでも増減させると呼び出し先がずれる。
  lib LibDynamicLoad
    alias HModule = Void*

    fun load_library_w = LoadLibraryW(file_name : UInt16*) : HModule
    fun get_proc_address = GetProcAddress(module : HModule, name : UInt8*) : Void*
    fun free_library = FreeLibrary(module : HModule) : Int32
  end

  lib LibOpenVR
    # EVRApplicationType_VRApplication_Overlay
    APPLICATION_TYPE_OVERLAY = 2
    # EVRInitError_VRInitError_None と EVRApplicationError_VRApplicationError_None
    ERROR_NONE = 0
    # EVREventType_VREvent_Quit
    EVENT_QUIT = 700

    # VREvent_t は openvr_capi.h で 4 バイト境界に詰められている。
    # data の中身は使わないため、大きさだけを合わせたバイト列として宣言する。
    struct VREvent
      event_type : UInt32
      tracked_device_index : UInt32
      event_age_seconds : Float32
      data : UInt8[48]
    end

    # VR_IVRSystem_FnTable（要素数 51）
    struct IVRSystemFnTable
      get_recommended_render_target_size : Void*                      # GetRecommendedRenderTargetSize
      get_projection_matrix : Void*                                   # GetProjectionMatrix
      get_projection_raw : Void*                                      # GetProjectionRaw
      compute_distortion : Void*                                      # ComputeDistortion
      compute_distortion_set : Void*                                  # ComputeDistortionSet
      get_eye_to_head_transform : Void*                               # GetEyeToHeadTransform
      get_time_since_last_vsync : Void*                               # GetTimeSinceLastVsync
      get_d3_d9_adapter_index : Void*                                 # GetD3D9AdapterIndex
      get_d_x_g_i_output_info : Void*                                 # GetDXGIOutputInfo
      get_output_device : Void*                                       # GetOutputDevice
      is_display_on_desktop : Void*                                   # IsDisplayOnDesktop
      set_display_visibility : Void*                                  # SetDisplayVisibility
      get_device_to_absolute_tracking_pose : Void*                    # GetDeviceToAbsoluteTrackingPose
      get_seated_zero_pose_to_standing_absolute_tracking_pose : Void* # GetSeatedZeroPoseToStandingAbsoluteTrackingPose
      get_raw_zero_pose_to_standing_absolute_tracking_pose : Void*    # GetRawZeroPoseToStandingAbsoluteTrackingPose
      get_sorted_tracked_device_indices_of_class : Void*              # GetSortedTrackedDeviceIndicesOfClass
      get_tracked_device_activity_level : Void*                       # GetTrackedDeviceActivityLevel
      apply_transform : Void*                                         # ApplyTransform
      get_tracked_device_index_for_controller_role : Void*            # GetTrackedDeviceIndexForControllerRole
      get_controller_role_for_tracked_device_index : Void*            # GetControllerRoleForTrackedDeviceIndex
      get_tracked_device_class : Void*                                # GetTrackedDeviceClass
      is_tracked_device_connected : Void*                             # IsTrackedDeviceConnected
      get_bool_tracked_device_property : Void*                        # GetBoolTrackedDeviceProperty
      get_float_tracked_device_property : Void*                       # GetFloatTrackedDeviceProperty
      get_int32_tracked_device_property : Void*                       # GetInt32TrackedDeviceProperty
      get_uint64_tracked_device_property : Void*                      # GetUint64TrackedDeviceProperty
      get_matrix34_tracked_device_property : Void*                    # GetMatrix34TrackedDeviceProperty
      get_array_tracked_device_property : Void*                       # GetArrayTrackedDeviceProperty
      get_string_tracked_device_property : Void*                      # GetStringTrackedDeviceProperty
      get_prop_error_name_from_enum : Void*                           # GetPropErrorNameFromEnum
      poll_next_event : Void*                                         # PollNextEvent
      poll_next_event_with_pose : Void*                               # PollNextEventWithPose
      poll_next_event_with_pose_and_overlays : Void*                  # PollNextEventWithPoseAndOverlays
      get_event_type_name_from_enum : Void*                           # GetEventTypeNameFromEnum
      get_hidden_area_mesh : Void*                                    # GetHiddenAreaMesh
      get_eye_tracked_foveation_center : Void*                        # GetEyeTrackedFoveationCenter
      get_eye_tracked_foveation_center_for_projection : Void*         # GetEyeTrackedFoveationCenterForProjection
      get_controller_state : Void*                                    # GetControllerState
      get_controller_state_with_pose : Void*                          # GetControllerStateWithPose
      trigger_haptic_pulse : Void*                                    # TriggerHapticPulse
      get_button_id_name_from_enum : Void*                            # GetButtonIdNameFromEnum
      get_controller_axis_type_name_from_enum : Void*                 # GetControllerAxisTypeNameFromEnum
      is_input_available : Void*                                      # IsInputAvailable
      is_steam_v_r_drawing_controllers : Void*                        # IsSteamVRDrawingControllers
      should_application_pause : Void*                                # ShouldApplicationPause
      should_application_reduce_rendering_work : Void*                # ShouldApplicationReduceRenderingWork
      perform_firmware_update : Void*                                 # PerformFirmwareUpdate
      acknowledge_quit_exiting : Void*                                # AcknowledgeQuit_Exiting
      get_app_container_file_paths : Void*                            # GetAppContainerFilePaths
      get_runtime_version : Void*                                     # GetRuntimeVersion
      set_s_d_k_version : Void*                                       # SetSDKVersion
    end

    # VR_IVRApplications_FnTable（要素数 31）
    struct IVRApplicationsFnTable
      add_application_manifest : Void*                   # AddApplicationManifest
      remove_application_manifest : Void*                # RemoveApplicationManifest
      is_application_installed : Void*                   # IsApplicationInstalled
      get_application_count : Void*                      # GetApplicationCount
      get_application_key_by_index : Void*               # GetApplicationKeyByIndex
      get_application_key_by_process_id : Void*          # GetApplicationKeyByProcessId
      launch_application : Void*                         # LaunchApplication
      launch_template_application : Void*                # LaunchTemplateApplication
      launch_application_from_mime_type : Void*          # LaunchApplicationFromMimeType
      launch_dashboard_overlay : Void*                   # LaunchDashboardOverlay
      cancel_application_launch : Void*                  # CancelApplicationLaunch
      identify_application : Void*                       # IdentifyApplication
      get_application_process_id : Void*                 # GetApplicationProcessId
      get_applications_error_name_from_enum : Void*      # GetApplicationsErrorNameFromEnum
      get_application_property_string : Void*            # GetApplicationPropertyString
      get_application_property_bool : Void*              # GetApplicationPropertyBool
      get_application_property_uint64 : Void*            # GetApplicationPropertyUint64
      set_application_auto_launch : Void*                # SetApplicationAutoLaunch
      get_application_auto_launch : Void*                # GetApplicationAutoLaunch
      set_default_application_for_mime_type : Void*      # SetDefaultApplicationForMimeType
      get_default_application_for_mime_type : Void*      # GetDefaultApplicationForMimeType
      get_application_supported_mime_types : Void*       # GetApplicationSupportedMimeTypes
      get_applications_that_support_mime_type : Void*    # GetApplicationsThatSupportMimeType
      get_application_launch_arguments : Void*           # GetApplicationLaunchArguments
      get_starting_application : Void*                   # GetStartingApplication
      get_scene_application_state : Void*                # GetSceneApplicationState
      perform_application_prelaunch_check : Void*        # PerformApplicationPrelaunchCheck
      get_scene_application_state_name_from_enum : Void* # GetSceneApplicationStateNameFromEnum
      launch_internal_process : Void*                    # LaunchInternalProcess
      register_subprocess : Void*                        # RegisterSubprocess
      get_current_scene_process_id : Void*               # GetCurrentSceneProcessId
    end

    alias PVREvent = VREvent*
  end
end
