import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'dart:async';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/services.dart'; // For SystemChrome and HapticFeedback
import 'package:flutter_tts/flutter_tts.dart'; // For Text-to-Speech
import 'package:http/http.dart' as http; // For making HTTP requests to Gemini API
import 'dart:convert'; // For base64 encoding
import 'dart:io'; // For File operations (reading image bytes)
import 'dart:typed_data'; // For Uint8List
import 'package:shared_preferences/shared_preferences.dart'; // For saving usage count


// GLOBAL VARIABLE: This will store the list of available cameras on the device.
// It's initialized once when the app starts.
late List<CameraDescription> cameras;

// Enum for supported application languages.
enum AppLanguage { ml, en, ta, hi }

// Enum for different application modes (Normal vs. VP - Voice Pilot).
enum AppMode { normal, vp }

Future<void> main() async {
  // Ensures that Flutter plugin services are initialized before using camera or other plugins.
  WidgetsFlutterBinding.ensureInitialized();
  print("Main: WidgetsFlutterBinding initialized."); // Debug print

  // Attempt to fetch the list of available cameras on the device.
  try {
    cameras = await availableCameras();
    print("Main: Successfully fetched ${cameras.length} cameras."); // Debug print
  } on CameraException catch (e) {
    print('Main Error: Camera Exception in availableCameras() - ${e.code}\nError Description: ${e.description}'); // Debug print
    // If no cameras are found or an error occurs, ensure 'cameras' is an empty list
    // to prevent null errors later.
    cameras = [];
  } catch (e) {
    print('Main Error: Unexpected error in availableCameras() - $e'); // Debug print
    cameras = [];
  }

  // Run the main application widget.
  runApp(const MyApp());
  print("Main: runApp called."); // Debug print
}

// The root widget of the application, defining the overall theme.
class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    print("MyApp: Building MaterialApp."); // Debug print
    return MaterialApp(
      title: 'Visual Pair', // Application title for the app switcher/task manager.
      theme: ThemeData(
        brightness: Brightness.dark, // Use a dark theme as standard for camera apps.
        primarySwatch: Colors.blue, // Default accent color for some widgets.
        visualDensity: VisualDensity.adaptivePlatformDensity, // Adapts UI to platform's density.
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.transparent, // AppBar background is transparent by default.
          elevation: 0, // No shadow under the AppBar.
        ),
        // Define text themes for consistency across the app, especially for pop-ups.
        dialogTheme: DialogThemeData(
          backgroundColor: const Color(0xFF282C34), // Dark blue-gray background for pop-ups.
          titleTextStyle: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
          contentTextStyle: const TextStyle(color: Colors.white70),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      ),
      home: const CameraViewScreen(), // Set CameraViewScreen as the initial screen.
      debugShowCheckedModeBanner: false, // Hide the debug banner.
    );
  }
}

// CameraViewScreen is a StatefulWidget as it manages mutable state.
class CameraViewScreen extends StatefulWidget {
  const CameraViewScreen({super.key});

  @override
  State<CameraViewScreen> createState() => _CameraViewScreenState();
}

// _CameraViewScreenState manages the state and logic for the camera view.
// It uses SingleTickerProviderStateMixin for AnimationControllers.
class _CameraViewScreenState extends State<CameraViewScreen> with SingleTickerProviderStateMixin {
  CameraController? _cameraController; // Controller for the camera.
  bool _isLoadingApp = true; // Indicates if the initial app assets/services are loading.
  bool _isCameraInitialized = false; // Indicates if the camera controller is initialized.
  bool _isProcessing = false; // Indicates if an image capture/API call/TTS is in progress.
  AppMode _currentAppMode = AppMode.normal; // Current application mode (Normal/VP).

  // Animation controller and animation for the flickering app icon on the loading screen.
  late AnimationController _flickerAnimationController;
  late Animation<double> _flickerAnimation;

  // Live data from native Android side (light sensor and volume percentage).
  double _currentLux = 0.0;
  int _currentVolumePercentage = 0;

  // Flutter Text-to-Speech instance.
  final FlutterTts _tts = FlutterTts();

  // MethodChannels and EventChannels for communication with native Android (Kotlin) code.
  static const lightSensorEventChannel = EventChannel('samples.flutter.dev/lightSensor');
  static const audioManagerMethodChannel = MethodChannel('audio_manager_channel');
  static const volumeButtonMethodChannel = MethodChannel('volume_button_channel');

  // TODO: IMPORTANT: Replace with your actual Gemini API key.
  // In a production app, never hardcode API keys. Use environment variables or a secure configuration method.
  final String _apiKey = "AIzaSyAB36rkbgQRL-m3NFvZP3CEfVxYSn-oyyo"; // Replace with your actual Gemini API Key.

  // Language management variables.
  AppLanguage _selectedAppLanguage = AppLanguage.ml; // Default language: Malayalam. ALWAYS MALAYALAM
  String _lastDescription = ""; // Stores the last Gemini description to avoid immediate repetition.
  int _usageCount = 0; // Daily API usage count.

  // Maps for Text-to-Speech language codes and Gemini prompt suffixes for localization.
  static const Map<AppLanguage, String> _ttsLanguageCodes = {
    AppLanguage.ml: "ml-IN",
    AppLanguage.en: "en-US", // or "en-IN" for Indian English accent.
    AppLanguage.ta: "ta-IN",
    AppLanguage.hi: "hi-IN",
  };

  static const Map<AppLanguage, String> _geminiPromptSuffixes = {
    AppLanguage.ml: "ദയവായി മലയാളത്തിൽ മാത്രം മറുപടി നൽകുക.",
    AppLanguage.en: "Please reply only in English.",
    AppLanguage.ta: "தமிழில் மட்டும் பதில் சொல்லுங்க.",
    AppLanguage.hi: "कृपया केवल हिंदी में उत्तर दें।",
  };

  // Map containing all application-specific text strings, translated by language.
  static const Map<AppLanguage, Map<String, String>> _mainPrompts = {
    AppLanguage.ml: {
      'brief': "ഈ ചിത്രം ചുരുക്കി വിശദീകരിക്കുക. പ്രധാന വിവരങ്ങൾ മാത്രം നൽകുക.",
      'detailed': "ഈ ചിത്രം വിശദീകരിക്കുക. ഇതിനെക്കുറിച്ച് കഴിയുന്നത്ര വിവരങ്ങൾ നൽകുക. ചിത്രത്തിലെ വസ്തുക്കൾ, നിറങ്ങൾ, സ്ഥാനങ്ങൾ, അതിൻ്റെ പൊതുവായ പശ്ചാത്തലം എന്നിവയെക്കുറിച്ച് വിശദീകരിക്കുക.",
      'cam_not_ready': "ക്യാമറ തയ്യാറല്ല അല്ലെങ്കിൽ ചിത്രം എടുക്കുന്നു.",
      'cam_not_available': "ക്യാമറ ലഭ്യമല്ല.",
      'cam_permission_denied': "ക്യാമറ അനുമതി ലഭിച്ചില്ല.",
      'cam_init_failed': "ക്യാമറ ആരംഭിക്കാൻ കഴിഞ്ഞില്ല.",
      'image_taken': "ചിത്രം എടുത്തു",
      'flash_on_dark': "ഇരുണ്ടിരിക്കുന്നു, പ്രകാശം ഓണാക്കുന്നു",
      'flash_off': "പ്രകാശം ഓഫ് ചെയ്തു",
      'flash_on': "പ്രകാശം ഓൺ ചെയ്തു",
      'description_failed': "ചിത്രം വിശദീകരിക്കാൻ കഴിയുന്നില്ല.",
      'similar_image': "സമാനമായ ചിത്രം.",
      'capture_failed': "ചിത്രം എടുക്കാൻ പറ്റിയില്ല.",
      'processing_msg': "പ്രോസസ്സിംഗ്...", // Renamed to avoid confusion with var
      'speaking_response_msg': "പ്രതികരിക്കുന്നു...", // Renamed to avoid confusion with var
      'language_changed': "ഭാഷ മാറ്റി.",
      'mode_normal_enter': "സാധാരണ മോഡിൽ പ്രവേശിക്കുന്നു. നിയന്ത്രണങ്ങൾ UI വഴി.",
      'mode_vp_enter': "വി പി മോഡിൽ പ്രവേശിക്കുന്നു. നിയന്ത്രണങ്ങൾ സ്വാപ്പ് ജെസ്റ്ററുകളിലൂടെ.",
      'usage': "ഉപയോഗം",
      'info_guide': "ഉപയോഗ മാർഗ്ഗരേഖ",
      'info_normal_mode': "സാധാരണ മോഡിൽ: ചിത്രം പകർത്താൻ ചുവന്ന ബട്ടൺ ടാപ്പ് ചെയ്യുക. വിശദമായ വിവരണത്തിനായി അമർത്തിപ്പിടിക്കുക. ഭാഷ മാറ്റാൻ ലോക ചിഹ്നം ഉപയോഗിക്കുക. ഉപയോഗ ഗൈഡിനായി വിവര ചിഹ്നം ടാപ്പ് ചെയ്യുക.",
      'info_vp_mode': "വിപി മോഡിൽ: ചുരുക്ക വിവരണം ലഭിക്കാൻ വലത്തേക്ക് സ്വൈപ്പ് ചെയ്യുക. വിശദമായ വിവരണത്തിനായി ഇടത്തേക്ക് സ്വൈപ്പ് ചെയ്യുക. ഭാഷ മാറ്റാൻ സ്ക്രീനിൽ ഇരട്ട ടാപ്പ് ചെയ്യുക. മോഡ് മാറ്റാൻ വോളിയം ബട്ടൺ അമർത്തിപ്പിടിക്കുക.",
      'no_description': "വിവരണം ലഭ്യമല്ല.",
      'controls_gestures_only': "ഈ മോഡിൽ ആംഗ്യങ്ങളിലൂടെയാണ് നിയന്ത്രണം.",
      'current_time': "നിലവിലെ സമയം",
    },
    AppLanguage.en: {
      'brief': "Briefly describe this image. Provide only important information.",
      'detailed': "Describe this image in detail. Provide as much information as possible about it. Explain objects, colors, positions, and its general background.",
      'cam_not_ready': "Camera not ready or taking picture.",
      'cam_not_available': "Camera not available.",
      'cam_permission_denied': "Camera permission denied.",
      'cam_init_failed': "Failed to initialize camera.",
      'image_taken': "Image captured",
      'flash_on_dark': "It's dark, turning on flash",
      'flash_off': "Flash off",
      'flash_on': "Flash on",
      'description_failed': "Unable to describe image.",
      'similar_image': "Similar image.",
      'capture_failed': "Failed to capture image.",
      'processing_msg': "Processing...",
      'speaking_response_msg': "Speaking response...",
      'language_changed': "Language changed.",
      'mode_normal_enter': "Entering Normal Mode. Controls via UI.",
      'mode_vp_enter': "Entering V P Mode. Controls via swipe gestures.",
      'usage': "Usage",
      'info_guide': "Usage Guide",
      'info_normal_mode': "In Normal Mode: Tap the red button to capture a photo and get a brief description. Long press for a detailed description. Use the globe icon to change language. Tap the info icon for this guide.",
      'info_vp_mode': "In VP Mode: Swipe right for a brief description. Swipe left for a detailed description. Double tap the screen to cycle languages. Long press volume button to toggle mode.",
      'no_description': "No description available.",
      'controls_gestures_only': "Controls in this mode are via gestures.",
      'current_time': "Current time",
    },
    AppLanguage.ta: {
      'brief': "இந்தக் காட்சியைச் சுருக்கமா சொல்லுங்க. முக்கிய விஷயங்களை மட்டும் கொடுங்க.",
      'detailed': "இந்தக் காட்சியைப் பத்தி விரிவா சொல்லுங்க. இதுல என்னென்ன இருக்கு, கலர்கள், எங்க இருக்கு, பொதுவா என்ன பின்னணிங்குறத பத்தி முடிஞ்ச அளவுக்கு தகவல் கொடுங்க.",
      'cam_not_ready': "கேமரா தயாரில்லை அல்லது படம் எடுக்குது.",
      'cam_not_available': "கேமரா கிடைக்கல.",
      'cam_permission_denied': "கேமரா அனுமதி மறுக்கப்பட்டது.",
      'cam_init_failed': "கேமராவை ஆன் பண்ண முடியல.",
      'image_taken': "படம் எடுத்தாச்சு.",
      'flash_on_dark': "வெளிச்சம் கம்மியா இருக்கு, ஃபிளாஷ் எரியுது.",
      'flash_off': "ஃபிளாஷ் ஆஃப் பண்ணியாச்சு.",
      'flash_on': "ஃபிளாஷ் எரியுது.",
      'description_failed': "படத்தை விவரிக்க முடியல.",
      'similar_image': "அதே மாதிரி படம்.",
      'capture_failed': "படம் எடுக்க முடியல.",
      'processing_msg': "செயல்படுத்திட்டு இருக்கு...",
      'speaking_response_msg': "பதில சொல்லிட்டு இருக்கு...",
      'language_changed': "மொழி மாத்தியாச்சு.",
      'mode_normal_enter': "சாதாரண மோடுக்கு போகுது. கண்ட்ரோல்கள் ஸ்கிரீன்ல இருக்கும்.",
      'mode_vp_enter': "வி பி மோடுக்கு போகுது. கண்ட்ரோல்கள் சைகைகள் வழியா.",
      'usage': "பயன்பாடு",
      'info_guide': "பயன்பாட்டு வழிகாட்டி",
      'info_normal_mode': "சாதாரண மோடுல: படமெடுக்க சிவப்பு பட்டனைத் தட்டுங்கள். விரிவான விளக்கத்திற்கு நீண்ட நேரம் அழுத்திப் பிடியுங்கள். மொழியை மாற்ற பூமி ஐகானைப் பயன்படுத்துங்கள். இந்த வழிகாட்டிக்கு தகவல் ஐகானைத் தட்டுங்கள்.",
      'info_vp_mode': "விபி மோடுல: சுருக்கமான விளக்கத்திற்கு வலதுபுறம் ஸ்வைப் பண்ணுங்க. விரிவான விளக்கத்திற்கு இடதுபுறம் ஸ்வைப் பண்ணுங்க. மொழியை மாற்ற ஸ்கிரீனை இருமுறை தட்டுங்க. மோடை மாற்ற வால்யூம் பட்டனை நீண்ட நேரம் அழுத்திப் பிடிங்க.",
      'no_description': "விளக்கம் கிடைக்கல.",
      'controls_gestures_only': "இந்த மோடில் சைகைகள் மூலம் கட்டுப்படுத்தப்படுகிறது.",
      'current_time': "தற்போதைய நேரம்",
    },
    AppLanguage.hi: {
      'brief': "इस चित्र का संक्षेप में वर्णन करें। केवल महत्वपूर्ण जानकारी प्रदान करें।",
      'detailed': "इस चित्र का विस्तार से वर्णन करें। इसके बारेG. में यथासंभव अधिक जानकारी प्रदान करें। वस्तुओं, रंगों, स्थितियों और इसकी सामान्य पृष्ठभूमि के बारे में बताएं।",
      'cam_not_ready': "कैमरा तैयार नहीं है या तस्वीर ले रहा है।",
      'cam_not_available': "कैमरा उपलब्ध नहीं है।",
      'cam_permission_denied': "कैमरा अनुमति अस्वीकृत।",
      'cam_init_failed': "कैमरा प्रारंभ करने में विफल।",
      'image_taken': "तस्वीर खींची गई",
      'flash_on_dark': "अंधेरा है, फ्लैश चालू हो रहा है",
      'flash_off': "फ्लैश बंद",
      'flash_on': "फ्लैश चालू",
      'description_failed': "छवि का वर्णन करने में असमर्थ।",
      'similar_image': "समान छवि।",
      'capture_failed': "तस्वीर लेने में विफल।",
      'processing_msg': "प्रसंस्करण हो रहा है...",
      'speaking_response_msg': "उत्तर बोला जा रहा है...",
      'language_changed': "भाषा बदल गई।",
      'mode_normal_enter': "सामान्य मोड में प्रवेश कर रहे हैं। UI द्वारा नियंत्रण।",
      'mode_vp_enter': "वी पी मोड में प्रवेश कर रहे हैं। स्वाइप जेस्चर द्वारा नियंत्रण।",
      'usage': "उपयोग",
      'info_guide': "उपयोगकर्ता मार्गदर्शिका",
      'info_normal_mode': "सामान्य मोड में: फ़ोटो लेने और संक्षिप्त विवरण प्राप्त करने के लिए लाल बटन पर टैप करें। विस्तृत विवरण के लिए देर तक दबाएँ। भाषा बदलने के लिए ग्लोब आइकन का उपयोग करें। इस मार्गदर्शिका के लिए जानकारी आइकन पर टैप करें।",
      'info_vp_mode': "वीपी मोड में: संक्षिप्त विवरण के लिए दाईं ओर स्वाइप करें। विस्तृत विवरण के लिए बाईं ओर स्वाइप करें। भाषा बदलने के लिए स्क्रीन पर डबल टैप करें। मोड बदलने के लिए वॉल्यूम बटन को देर तक दबाएँ।",
      'no_description': "कोई विवरण उपलब्ध नहीं है।",
      'controls_gestures_only': "इस मोड में नियंत्रण जेस्चर के माध्यम से होते हैं।",
      'current_time': "वर्तमान समय",
    },
  };

  // Helper function to get translated text based on selected language.
  String _getTranslatedText(String key) {
    return _mainPrompts[_selectedAppLanguage]?[key] ?? _mainPrompts[AppLanguage.en]?[key] ?? key;
  }


  @override
  void initState() {
    super.initState();
    print("CameraViewScreen: initState called."); // Debug print

    // Initialize flicker animation for the app icon.
    _flickerAnimationController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600), // Slower flicker effect.
    )..repeat(reverse: true); // Repeat animation continuously.
    _flickerAnimation = Tween<double>(begin: 0.5, end: 1.0).animate(_flickerAnimationController);
    print("CameraViewScreen: Flicker animation controller initialized."); // Debug print

    // Initialize TTS
    _setupTTS();

    // Load usage count for Gemini API calls.
    _loadUsageCount();

    // Start camera initialization and setup process.
    _initializeCameraAndSetup();
    _setupPlatformChannels(); // Setup platform channels here (volume buttons, light sensor).
    print("CameraViewScreen: _initializeCameraAndSetup and _setupPlatformChannels called."); // Debug print
  }

  // Initializes the camera, handles permissions, and manages loading state.
  Future<void> _initializeCameraAndSetup() async {
    print("InitializeCameraAndSetup: Function started."); // Debug print

    // Simulate initial loading time for a minimum duration (e.g., 2 seconds)
    // This ensures the loading screen is visible for a short period before main UI appears.
    print("InitializeCameraAndSetup: Delaying for splash screen (2 seconds)."); // Debug print
    await Future.delayed(const Duration(seconds: 4));
    print("InitializeCameraAndSetup: Delay finished."); // Debug print

    // Request camera permission.
    print("InitializeCameraAndSetup: Requesting camera permission..."); // Debug print
    var status = await Permission.camera.request();
    print("InitializeCameraAndSetup: Camera permission status: $status"); // Debug print

    if (status.isGranted) {
      print("InitializeCameraAndSetup: Permission granted. Checking global cameras list..."); // Debug print
      if (cameras.isNotEmpty) { // Use the global 'cameras' list initialized in main().
        // Select the first available camera.
        _cameraController = CameraController(cameras[0], ResolutionPreset.high);
        try {
          await _cameraController!.initialize(); // Initialize the camera controller.
          print("InitializeCameraAndSetup: CameraController initialized successfully."); // Debug print
          if (!mounted) {
            print("InitializeCameraAndSetup: Widget not mounted after camera init. Returning."); // Debug print
            return;
          }
          setState(() {
            _isCameraInitialized = true; // Mark camera as initialized.
            _isLoadingApp = false; // Turn off initial loading screen.
          });
          print("InitializeCameraAndSetup: _isCameraInitialized set to true, _isLoadingApp set to false."); // Debug print
        } on CameraException catch (e) {
          print('InitializeCameraAndSetup Error: Camera Controller Init failed - ${e.code}\nDescription: ${e.description}'); // Debug print
          if (!mounted) return;
          setState(() {
            _isCameraInitialized = false; // Ensure it stays false on error.
            _isLoadingApp = false; // Turn off initial loading screen even on error.
          });
          _showErrorDialog("Camera Init Failed", "${_getTranslatedText('cam_init_failed')} Error: ${e.description}"); // Show an actual dialog with translated text.
        } catch (e) {
          print('InitializeCameraAndSetup Error: Unexpected error during Camera Init - $e'); // Debug print
          if (!mounted) return;
          setState(() {
            _isCameraInitialized = false; // Ensure it stays false on error.
            _isLoadingApp = false; // Turn off initial loading screen even on error.
          });
          _showErrorDialog("Camera Init Failed", "${_getTranslatedText('cam_init_failed')} An unexpected error occurred: $e"); // Show an actual dialog with translated text.
        }
      } else {
        print("InitializeCameraAndSetup: Global 'cameras' list is EMPTY. No cameras available."); // Debug print
        if (!mounted) return;
        setState(() {
          _isLoadingApp = false; // Turn off initial loading screen.
        });
        _showErrorDialog("No camera found", _getTranslatedText('cam_not_available')); // Show dialog with translated text.
      }
    } else {
      print("InitializeCameraAndSetup: Camera permission DENIED."); // Debug print
      if (!mounted) return;
      setState(() {
        _isLoadingApp = false; // Turn off initial loading screen.
      });
      _showErrorDialog(
          "Camera Permission Denied", _getTranslatedText('cam_permission_denied')); // Show dialog with translated text.
    }
  }

  // Sets up the platform channels for communication with native Android code.
  void _setupPlatformChannels() {
    print("SetupPlatformChannels: Setting up platform channels."); // Debug print

    // Light Sensor Event Channel
    lightSensorEventChannel.receiveBroadcastStream().listen((lux) {
      setState(() {
        _currentLux = lux.toDouble();
      });
    }, onError: (e) {
      print("Error on lightSensorEventChannel: $e");
    });

    // Audio Manager Method Channel
    audioManagerMethodChannel.setMethodCallHandler((call) async {
      if (call.method == "volumePercentageChanged") {
        setState(() {
          _currentVolumePercentage = call.arguments as int;
        });
      }
      return;
    });

    // Volume Button Method Channel (handles short and long presses).
    volumeButtonMethodChannel.setMethodCallHandler((call) async {
      print("VolumeButton: Method call received: ${call.method}"); // Debug print
      switch (call.method) {
        case "volumeUpPressed":
          print("Volume Up Short Press Detected");
          HapticFeedback.lightImpact(); // Haptic feedback.
          _captureImage(detailed: false); // Trigger brief description.
          break;
        case "volumeDownPressed":
          print("Volume Down Short Press Detected");
          HapticFeedback.lightImpact(); // Haptic feedback.
          // Format the time string according to locale or preference for better TTS.
          String timeString = "${DateTime.now().hour}:${DateTime.now().minute.toString().padLeft(2, '0')}";
          await _tts.speak("${_getTranslatedText('current_time')} $timeString."); // Speak current time.
          break;
        case "volumeUpLongPressed": // This button now Toggles mode (Normal <-> VP)
          print("Volume Up Long Press Detected - Toggling Mode");
          HapticFeedback.heavyImpact(); // Stronger haptic feedback for mode change.
          setState(() {
            _currentAppMode = _currentAppMode == AppMode.normal ? AppMode.vp : AppMode.normal;
          });
          print("Mode changed to: $_currentAppMode");
          await _tts.speak(_currentAppMode == AppMode.normal ? _getTranslatedText('mode_normal_enter') : _getTranslatedText('mode_vp_enter'));
          break;
        case "volumeDownLongPressed": // This button also Toggles mode (Normal <-> VP)
          print("Volume Down Long Press Detected - Toggling Mode");
          HapticFeedback.heavyImpact(); // Stronger haptic feedback for mode change.
          setState(() {
            _currentAppMode = _currentAppMode == AppMode.normal ? AppMode.vp : AppMode.normal;
          });
          print("Mode changed to: $_currentAppMode");
          await _tts.speak(_currentAppMode == AppMode.normal ? _getTranslatedText('mode_normal_enter') : _getTranslatedText('mode_vp_enter'));
          break;
        default:
          break;
      }
      if (mounted) {
        setState(() {}); // Update UI after volume button action.
      }
      return;
    });

    audioManagerMethodChannel.invokeMethod('requestInitialVolumePercentage'); // Request initial volume state.
    print("SetupPlatformChannels: Platform channels setup complete."); // Debug print
  }

  // Cleans up Gemini API responses (removes common intros, markdown).
  String _cleanGeminiOutput(String text) {
    String cleanedText = text;

    // Remove common introductory phrases from Gemini, localized for each language.
    cleanedText = cleanedText.replaceAll('തീർച്ചയായും,', ''); // Malayalam
    cleanedText = cleanedText.replaceAll('ഇതാ ചിത്രത്തെക്കുറിച്ചുള്ള വിവരണം.', '');
    cleanedText = cleanedText.replaceAll('ചിത്രത്തെക്കുറിച്ച് ഒരു ലഘു വിവരണം ഇതാ.', '');
    cleanedText = cleanedText.replaceAll('ചിത്രം ഇതാ വിശദീകരിക്കുന്നു.', '');

    cleanedText = cleanedText.replaceAll('Certainly,', ''); // English
    cleanedText = cleanedText.replaceAll('Here is a brief description of the image.', '');
    cleanedText = cleanedText.replaceAll('Here is a description of the image.', '');
    cleanedText = cleanedText.replaceAll('This image shows', '');

    cleanedText = cleanedText.replaceAll('निश्चित रूप से,', ''); // Hindi
    cleanedText = cleanedText.replaceAll('यह चित्र दिखाता है कि', '');
    cleanedText = cleanedText.replaceAll('इस चित्र का वर्णन इस प्रकार है।', '');

    cleanedText = cleanedText.replaceAll('നിശ്ചയമായും,', ''); // Malayalam alternative
    cleanedText = cleanedText.replaceAll('നൽകിയിട്ടുള്ള ചിത്രത്തെക്കുറിച്ചുള്ള വിവരണം ഇതാ:', '');
    cleanedText = cleanedText.replaceAll('ഈ ചിത്രത്തെക്കുറിച്ച് ഒരു വിവരണം നൽകാം:', '');
    cleanedText = cleanedText.replaceAll('നിങ്ങൾ നൽകിയ ചിത്രത്തെക്കുറിച്ചുള്ള വിവരണം ഇതാ:', '');
    cleanedText = cleanedText.replaceAll('ഇതാ ഒരു വിവരണം:', '');


    cleanedText = cleanedText.replaceAll('நிச்சயமாக,', ''); // Tamil
    cleanedText = cleanedText.replaceAll('இந்தக் காட்சியைப் பற்றிய விளக்கம் இதோ.', '');
    cleanedText = cleanedText.replaceAll('இந்தக் காட்சியைப் பற்றிய சுருக்கமான விளக்கம் இதோ.', '');
    cleanedText = cleanedText.replaceAll('கொடுக்கப்பட்ட படத்தை பற்றிய விளக்கம் இதோ:', '');
    cleanedText = cleanedText.replaceAll('படத்தைப் பற்றிய விளக்கம்:', '');
    cleanedText = cleanedText.replaceAll('நான் கொடுத்த படத்தைப் பற்றி சொல்லுகிறேன்:', '');


    // Remove bold markdown (e.g., **text** becomes text).
    cleanedText = cleanedText.replaceAllMapped(RegExp(r'\*\*([^*]+)\*\*'), (match) => match.group(1)!);
    // Remove italic/list item markdown (e.g., *text* or * list item).
    cleanedText = cleanedText.replaceAll('*', '');

    // Remove colons at the start or end of sentences if they appear.
    cleanedText = cleanedText.replaceAll(':', '');

    cleanedText = cleanedText.trim(); // Trim leading/trailing whitespace.

    if (cleanedText.isEmpty) {
      return _getTranslatedText('no_description'); // Fallback if cleaned text is empty.
    }

    return cleanedText;
  }

  // Sends an image to Gemini API for a brief description.
  Future<String?> _describeScene(Uint8List imageBytes) async {
    final url =
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=$_apiKey';

    final body = {
      "contents": [
        {
          "parts": [
            {
              "inline_data": {
                "mime_type": "image/jpeg",
                "data": base64Encode(imageBytes)
              }
            },
            {
              "text": "${_getTranslatedText('brief')} ${_geminiPromptSuffixes[_selectedAppLanguage]}"
            }
          ]
        }
      ]
    };

    try {
      final response = await http.post(Uri.parse(url),
          headers: {"Content-Type": "application/json"}, body: jsonEncode(body));

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        return _cleanGeminiOutput(json['candidates']?[0]?['content']?['parts']?[0]?['text']?.toString() ?? '');
      } else {
        print("API error: ${response.statusCode} - ${response.body}");
        return null;
      }
    } catch (e) {
      print("Network error: $e");
      return null;
    }
  }

  // Sends an image to Gemini API for a detailed description.
  Future<String?> _describeSceneDetailed(Uint8List imageBytes) async {
    final url =
        'https://generativelanguage.googleapis.com/v1beta/models/gemini-1.5-flash:generateContent?key=$_apiKey';

    final body = {
      "contents": [
        {
          "parts": [
            {
              "inline_data": {
                "mime_type": "image/jpeg",
                "data": base64Encode(imageBytes) // Encode image to base64.
              }
            },
            {
              // Detailed prompt with language suffix.
              "text": "${_getTranslatedText('detailed')} ${_geminiPromptSuffixes[_selectedAppLanguage]}"
            }
          ]
        }
      ]
    };

    try {
      final response = await http.post(Uri.parse(url),
          headers: {"Content-Type": "application/json"}, body: jsonEncode(body));

      if (response.statusCode == 200) {
        final json = jsonDecode(response.body);
        // Extract and clean the description from the API response.
        return _cleanGeminiOutput(json['candidates']?[0]?['content']?['parts']?[0]?['text']?.toString() ?? '');
      } else {
        print("API error: ${response.statusCode} - ${response.body}");
        return null;
      }
    } catch (e) {
      print("Error describing scene detailed: $e");
      return null;
    }
  }

  // Core function to capture an image and get its description (brief or detailed).
  Future<void> _captureImage({bool detailed = false}) async {
    // Prevent capture if camera is not ready or already taking a picture.
    if (_cameraController == null || !_cameraController!.value.isInitialized || _cameraController!.value.isTakingPicture || !mounted) {
      await _tts.speak(_getTranslatedText('cam_not_ready'));
      return;
    }

    await _tts.stop(); // Stop any ongoing speech.
    if (mounted) {
      setState(() {
        _isProcessing = true;
      });
    }
    await _tts.speak(_getTranslatedText('processing_msg')); // Announce processing.
    HapticFeedback.heavyImpact(); // Provide haptic feedback for capture.

    try {
      final XFile picture = await _cameraController!.takePicture(); // Take the picture.
      await _tts.speak(_getTranslatedText('image_taken')); // Announce image taken.

      final Uint8List bytes = await File(picture.path).readAsBytes(); // Read image bytes.
      String? description;
      if (detailed) {
        description = await _describeSceneDetailed(bytes); // Get detailed description.
      } else {
        description = await _describeScene(bytes); // Get brief description.
      }

      if (description != null && description.isNotEmpty && description != _lastDescription) {
        _lastDescription = description; // Store description to prevent immediate repetition.
        await _incrementUsageCount(); // Increment API usage count.

        if (mounted) {
          setState(() {
            // No central text update, just processing overlay.
          });
        }
        await _tts.speak(description); // Speak the description.
      } else if (description == null) {
        await _tts.speak(_getTranslatedText('description_failed')); // Announce failure.
      } else if (description == _lastDescription) {
        await _tts.speak(_getTranslatedText('similar_image')); // Announce similar image.
      }
    } catch (e) {
      await _tts.speak(_getTranslatedText('capture_failed')); // Announce capture failure.
      print("Capture error: $e");
    } finally {
      if (mounted) {
        setState(() {
          _isProcessing = false; // Hide processing overlay.
        });
      }
    }
  }

  // Loads the daily usage count from SharedPreferences.
  Future<void> _loadUsageCount() async {
    final prefs = await SharedPreferences.getInstance();
    final now = DateTime.now();
    final savedDate = prefs.getString('usageDate');

    // Reset usage count if the date is different (new day).
    if (savedDate == null || savedDate != now.toIso8601String().substring(0, 10)) {
      await prefs.setString('usageDate', now.toIso8601String().substring(0, 10));
      await prefs.setInt('usageCount', 0);
      _usageCount = 0;
    } else {
      _usageCount = prefs.getInt('usageCount') ?? 0;
    }
    if (mounted) {
      setState(() {}); // Update UI to show current usage count.
    }
    print("Loaded daily usage count: $_usageCount"); // Debug print
  }

  // Increments the daily usage count and saves it to SharedPreferences.
  Future<void> _incrementUsageCount() async {
    final prefs = await SharedPreferences.getInstance();
    _usageCount += 1;
    await prefs.setInt('usageCount', _usageCount);
    if (mounted) {
      setState(() {}); // Update UI to reflect incremented count.
    }
    print("Usage count incremented to: $_usageCount"); // Debug print
  }

  // Sets the application language, cycling through languages if specified.
  Future<void> _setAppLanguage({AppLanguage? newLang, bool cycle = false}) async {
    AppLanguage targetLang = _selectedAppLanguage;

    if (cycle) {
      int currentIndex = AppLanguage.values.indexOf(_selectedAppLanguage);
      int nextIndex = (currentIndex + 1) % AppLanguage.values.length;
      targetLang = AppLanguage.values[nextIndex];
    } else if (newLang != null) {
      targetLang = newLang;
    }

    if (targetLang == _selectedAppLanguage) {
      print("Language already set to $targetLang, no change needed."); // Debug print
      return; // No change needed.
    }

    setState(() {
      _selectedAppLanguage = targetLang;
    });
    // Removed saving language preference to SharedPreferences to force Malayalam default on launch.
    _setupTTS(); // Re-initialize TTS with the new language setting.
    await _tts.speak(_getTranslatedText('language_changed')); // Announce language change.
    print("Language changed to: $_selectedAppLanguage"); // Debug print
  }

  // Sets up the Text-to-Speech engine properties.
  void _setupTTS() {
    _tts.setLanguage(_ttsLanguageCodes[_selectedAppLanguage]!);
    _tts.setSpeechRate(0.45); // Set speech rate.
    _tts.setVolume(1.0); // Set volume.
    _tts.setPitch(1.0); // Set pitch.
    _tts.awaitSpeakCompletion(true); // Wait for speech to complete before next command.
    print("TTS setup with language: ${_ttsLanguageCodes[_selectedAppLanguage]}"); // Debug print
  }

  // Helper to show error dialogs.
  void _showErrorDialog(String title, String message) {
    print("Showing Error Dialog: $title - $message"); // Debug print
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(context).pop();
            },
            child: const Text("OK"),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    print("CameraViewScreen: dispose called."); // Debug print
    _cameraController?.dispose();
    _flickerAnimationController.dispose();
    _tts.stop(); // Stop any TTS speech.
    super.dispose();
  }

  // Event handler for the main capture button tap.
  void _onCapturePressed() async {
    print("Capture button pressed! Current mode: $_currentAppMode");
    // In Normal mode, single tap is for brief description
    if (_currentAppMode == AppMode.normal) {
      _captureImage(detailed: false);
    } else {
      await _tts.speak(_getTranslatedText('controls_gestures_only'));
    }
  }

  // Event handler for the main capture button long press.
  void _onCaptureLongPress() async {
    print("Capture button long pressed! Current mode: $_currentAppMode");
    // In Normal mode, long press is for detailed description
    if (_currentAppMode == AppMode.normal) {
      _captureImage(detailed: true);
    } else {
      await _tts.speak(_getTranslatedText('controls_gestures_only'));
    }
  }

  // Event handler for the language change button.
  void _onLanguageChangePressed() {
    print("Language change button pressed! Current mode: $_currentAppMode");
    if (_currentAppMode == AppMode.normal) {
      HapticFeedback.selectionClick(); // Haptic feedback.
      showDialog(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(_getTranslatedText('language_changed').split('.')[0]), // Use first part of translated text as title
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: AppLanguage.values.map((lang) {
              return ListTile(
                title: Text(lang.toString().split('.').last, // Displays "ml", "en" etc.
                    style: TextStyle(
                        color: _selectedAppLanguage == lang ? Theme.of(context).primaryColor : null)),
                onTap: () {
                  _setAppLanguage(newLang: lang); // Set new language.
                  Navigator.pop(context); // Close dialog.
                },
              );
            }).toList(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
          ],
        ),
      );
    } else {
      _tts.speak(_getTranslatedText('controls_gestures_only'));
    }
  }

  // Event handler for the info button.
  void _onInfoPressed() {
    print("Info button pressed! Current mode: $_currentAppMode");
    if (_currentAppMode == AppMode.normal) {
      HapticFeedback.selectionClick();
      showDialog(
        context: context,
        builder: (BuildContext context) {
          return AlertDialog(
            title: Text(_getTranslatedText("info_guide")), // Using translated "Usage Guide" as info dialog title.
            content: SingleChildScrollView(
              child: ListBody(
                children: <Widget>[
                  Text(_getTranslatedText("info_normal_mode")),
                  const SizedBox(height: 10),
                  Text(_getTranslatedText("info_vp_mode")),
                ],
              ),
            ),
            actions: <Widget>[
              TextButton(
                child: const Text("Got It"),
                onPressed: () {
                  Navigator.of(context).pop();
                },
              ),
            ],
          );
        },
      );
    } else {
      _tts.speak(_getTranslatedText('controls_gestures_only'));
    }
  }

  // --- Main Build Method ---
// --- Main Build Method ---
 // --- Main Build Method ---
  @override
  Widget build(BuildContext context) {
    // Keep the UI in immersive sticky mode (fullscreen).
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky, overlays: []);
    print("CameraViewScreen: Building UI. _isLoadingApp: $_isLoadingApp, _isCameraInitialized: $_isCameraInitialized, _currentAppMode: $_currentAppMode"); // Debug print

    // Calculate dynamic sizes based on screen width for responsiveness.
    final double screenWidth = MediaQuery.of(context).size.width;
    // Set capture button size to be 50% of the screen width for a truly large button.
    final double captureButtonSize = screenWidth * 0.20;
    // Inner circle is 50% of the outer button's size, maintaining proportion.
    final double innerCircleSize = captureButtonSize * 0.0;

    // Display loading screen if app is still initializing.
    if (_isLoadingApp) {
      print("CameraViewScreen: Displaying initial loading screen (white background)."); // Debug print
      return Scaffold(
        backgroundColor: Colors.white, // White background for loading screen.
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Flickering app icon for loading screen.
              FadeTransition(
                opacity: _flickerAnimation,
                child: Image.asset(
                  'assets/images/load.png', // Uses the single app icon.
                  width: 150,
                  height: 150,
                  fit: BoxFit.contain,
                ),
              ),
              const SizedBox(height: 20), // Spacing between image and progress indicator.
              // Circular loading progress indicator.
              CircularProgressIndicator(color: Theme.of(context).primaryColor),
            ],
          ),
        ),
      );
    }

    // Display a simple black screen with a spinner if camera is not yet initialized.
    // (This state should be very brief, transitioning from _isLoadingApp, or if camera init fails).
    if (!_isCameraInitialized) {
      print("CameraViewScreen: Displaying black screen with spinner (camera not initialized)."); // Debug print
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: CircularProgressIndicator(),
        ),
      );
    }

    // Main Camera View or VP Mode UI.
    print("CameraViewScreen: Displaying main camera/VP UI."); // Debug print
    return Scaffold(
      // Background color based on current mode.
      backgroundColor: _currentAppMode == AppMode.vp ? const Color(0xFF15171a) : Colors.black, // Dark blue-gray for VP mode.
      // Top App Bar (Slim Navbar).
      appBar: AppBar(
        backgroundColor: Colors.black.withOpacity(0.5), // Semi-transparent.
        elevation: 0, // No shadow.
        centerTitle: false, // Align title to left.
        title: Row(
          children: [
            // App Logo.
            Image.asset('assets/images/ui.png', height: 28), // Uses the single app icon.
            const SizedBox(width: 8),
            const Text(
              'Visual Pair', // App name.
              style: TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        actions: [
          // Usage count display (now includes more padding and visual styling).
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Theme.of(context).cardColor.withOpacity(0.8),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _getTranslatedText("usage"),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Colors.white.withOpacity(0.7),
                    fontSize: 9,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                Text(
                  "$_usageCount",
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8), // Padding.
        ],
      ),
      body: GestureDetector(
        // This GestureDetector handles common gestures across both modes.
        onDoubleTap: () {
          setState(() {
            // Toggle between Normal and VP mode on double tap.
            _currentAppMode = _currentAppMode == AppMode.normal ? AppMode.vp : AppMode.normal;
          });
          HapticFeedback.heavyImpact(); // Heavy haptic feedback for mode change.
          print("Mode changed to: $_currentAppMode");
          _tts.speak(_currentAppMode == AppMode.normal ? _getTranslatedText('mode_normal_enter') : _getTranslatedText('mode_vp_enter'));
        },
        // Handles horizontal drag for brief/detailed descriptions in VP mode.
        onHorizontalDragUpdate: (details) async {
          print("Gesture: Horizontal drag detected. Current mode: $_currentAppMode, isProcessing: $_isProcessing"); // Debug print
          if (!_isProcessing && _currentAppMode == AppMode.vp) { // Only active in VP mode when not processing.
            // Debounce the swipe gesture to prevent multiple triggers from one swipe.
            // Check for a significant horizontal swipe.
            if (details.primaryDelta!.abs() > 50) {
              if (details.primaryDelta! < 0) { // Swiping left for detailed description.
                await _captureImage(detailed: true);
              } else if (details.primaryDelta! > 0) { // Swiping right for brief description.
                await _captureImage(detailed: false);
              }
            }
          } else if (_currentAppMode == AppMode.normal) {
            print("Horizontal drag in Normal mode (inactive for actions).");
          }
        },
        child: Stack(
          children: [
            // Only show CameraPreview in Normal mode.
            if (_currentAppMode == AppMode.normal)
              Positioned.fill(
                child: AspectRatio(
                  aspectRatio: _cameraController!.value.aspectRatio,
                  child: CameraPreview(_cameraController!),
                ),
              )
            else // In VP mode, show a blank dark blue-gray screen with watermark.
              Container(
                color: const Color(0xFF15171a), // Dark blue-gray background for VP mode.
                child: Center(
                  child: Opacity(
                    opacity: 0.2, // Watermark effect.
                    child: Text(
                      'VP MODE',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: MediaQuery.of(context).size.width * 0.15, // Large font, scales with screen width.
                        fontWeight: FontWeight.w300, // Thinner font.
                      ),
                    ),
                  ),
                ),
              ),

            // Processing Overlay (visible in both Normal and VP modes when active).
            if (_isProcessing)
              Container(
                color: Colors.black.withOpacity(0.7), // Semi-transparent black overlay.
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const CircularProgressIndicator(color: Colors.white), // White spinner.
                      const SizedBox(height: 20),
                      Text(
                        _getTranslatedText('processing_msg'), // Display processing message.
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
      // Bottom Navigation Bar.
      bottomNavigationBar: _currentAppMode == AppMode.normal ? BottomAppBar( // Only show in Normal mode.
        color: Colors.black.withOpacity(0.5), // Semi-transparent.
        elevation: 0, // No shadow.
        // Explicitly set height for a tight fit, based on the large button's size.
        height: captureButtonSize + 20, // Button height + 10px top/bottom padding.
        child: Padding( // Add Padding to explicitly control horizontal space within the BottomAppBar.
          padding: const EdgeInsets.symmetric(horizontal: 4.0), // Minimal horizontal padding.
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly, // Distribute space evenly between and around children.
            children: <Widget>[
              // Lux and Vol on the left.
              Column(
                mainAxisSize: MainAxisSize.min, // Keep column compact.
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Lux: ${_currentLux.toStringAsFixed(1)}',
                    style: TextStyle(color: Colors.white70, fontSize: 13, shadows: [Shadow(blurRadius: 3, color: Colors.black.withOpacity(0.5))]),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Vol: ${_currentVolumePercentage}%',
                    style: TextStyle(color: Colors.white70, fontSize: 13, shadows: [Shadow(blurRadius: 3, color: Colors.black.withOpacity(0.5))]),
                  ),
                ],
              ),
              // Capture Button (dynamically sized using RawMaterialButton).
              GestureDetector( // GestureDetector wraps RawMaterialButton for tap/long press.
                onTap: _onCapturePressed, // Single tap for brief.
                onLongPress: _onCaptureLongPress, // Long press for detailed.
                child: RawMaterialButton(
                  onPressed: () {}, // Empty onPressed as GestureDetector handles actions.
                  fillColor: const Color.fromARGB(255, 255, 255, 255).withOpacity(0.9), // Button background color.
                  shape: const CircleBorder(), // Overall circular shape.
                  constraints: BoxConstraints.tightFor( // Explicitly force the size using calculated percentages.
                    width: captureButtonSize,
                    height: captureButtonSize,
                  ),
                  elevation: 6.0, // Mimic a FloatingActionButton's shadow.
                  child: Container( // Inner minimal white circular border.
                    width: innerCircleSize, // Use calculated inner size.
                    height: innerCircleSize, // Use calculated inner size.
                    decoration: BoxDecoration(
                      shape: BoxShape.circle
                    ),
                  ),
                ),
              ),
              // Language and Info buttons on the right.
              Row(
                mainAxisSize: MainAxisSize.min, // Keep Row compact for these icons.
                children: [
                  IconButton(
                    icon: const Icon(Icons.language, color: Colors.white, size: 24), // Reduced icon size for more space.
                    onPressed: _onLanguageChangePressed,
                    tooltip: 'Change Language',
                  ),
                  // Small explicit space between these two icons.
                  const SizedBox(width: 8),
                  IconButton(
                    icon: const Icon(Icons.info_outline, color: Colors.white, size: 24), // Reduced icon size for more space.
                    onPressed: _onInfoPressed,
                    tooltip: 'How to Use',
                  ),
                ],
              ),
            ],
          ),
        ),
      ) : null, // Hide BottomAppBar in VP mode.
    );
  }}