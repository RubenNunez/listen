# Data and privacy

Listen's default voice-assistant audio path runs recognition and synthesis on the
device. A first model/recognition-asset download uses the relevant host's network
service. A local model's license remains its own.

Selected text, topic context and relevant tool observations go to the reasoning
or routing providers you configure. Internet research uses the selected provider's
capability. Connected MCP servers receive the arguments for tools you authorize.
Local audio processing does not make a selected cloud reasoning provider offline.

Conversation recordings, transcripts and timeline events can be retained locally
for review under the app's recording settings. They are private user data, not
part of this repository. A conversation is started by the owner; capture respects
pause, interruption, background and stop boundaries.

The foreground idle orb can use the microphone as a level meter if you switch
the microphone on. That idle audio is measured and discarded, without a conversation
transcript or recording. Turn that switch off to stop the idle meter. This is separate
from starting or ending a recorded voice conversation.

Camera access is only for user-initiated pairing/setup QR codes, without retained
images, uploaded images or vision-model inference. This source distribution does
not contain another-app screen/audio capture.

There is no Listen-hosted inference service or mandatory Listen account. Using an
optional personal router involves your own configured infrastructure. Provider
accounts and operating-system permissions remain your choices and responsibilities.
