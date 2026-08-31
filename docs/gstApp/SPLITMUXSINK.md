Factory Details:
  Rank                     none (0)
  Long-name                Split Muxing Bin
  Klass                    Generic/Bin/Muxer
  Description              Convenience bin that muxes incoming streams into multiple time/size limited files
  Author                   Jan Schmidt <jan@centricular.com>

Plugin Details:
  Name                     multifile
  Description              Reads/Writes buffers from/to sequentially named files
  Filename                 /usr/lib/gstreamer-1.0/libgstmultifile.so
  Version                  1.18.0
  License                  LGPL
  Source module            gst-plugins-good
  Source release date      2020-09-08
  Binary package           GStreamer Good Plug-ins source release
  Origin URL               Unknown package origin

GObject
 +----GInitiallyUnowned
       +----GstObject
             +----GstElement
                   +----GstBin
                         +----GstSplitMuxSink

Implemented Interfaces:
  GstChildProxy

Pad Templates:
  SINK template: 'caption_%u'
    Availability: On request
    Capabilities:
      ANY

  SINK template: 'subtitle_%u'
    Availability: On request
    Capabilities:
      ANY

  SINK template: 'audio_%u'
    Availability: On request
    Capabilities:
      ANY

  SINK template: 'video_aux_%u'
    Availability: On request
    Capabilities:
      ANY

  SINK template: 'video'
    Availability: On request
    Capabilities:
      ANY

Element has no clocking capabilities.
Element has no URI handling capabilities.

Pads:
  none

Element Properties:
  alignment-threshold : Allow non-reference streams to be that many ns before the reference stream
                        flags: readable, writable, changeable only in NULL or READY state
                        Unsigned Integer64. Range: 0 - 18446744073709551615 Default: 0
  async-finalize      : Finalize each fragment asynchronously and start a new one
                        flags: readable, writable
                        Boolean. Default: false
  async-handling      : The bin will handle Asynchronous state changes
                        flags: readable, writable
                        Boolean. Default: false
  location            : Format string pattern for the location of the files to write (e.g. video%05d.mp4)
                        flags: readable, writable
                        String. Default: null
  max-files           : Maximum number of files to keep on disk. Once the maximum is reached,old files start to be deleted to make room for new ones.
                        flags: readable, writable
                        Unsigned Integer. Range: 0 - 4294967295 Default: 0
  max-size-bytes      : Max. amount of data per file (in bytes, 0=disable)
                        flags: readable, writable, changeable only in NULL or READY state
                        Unsigned Integer64. Range: 0 - 18446744073709551615 Default: 0
  max-size-time       : Max. amount of time per file (in ns, 0=disable)
                        flags: readable, writable, changeable only in NULL or READY state
                        Unsigned Integer64. Range: 0 - 18446744073709551615 Default: 0
  max-size-timecode   : Maximum difference in timecode between first and last frame. Separator is assumed to be ":" everywhere (e.g. 01:00:00:00). Will only be effective if a timecode track is present.
                        flags: readable, writable, changeable only in NULL or READY state
                        String. Default: null
  message-forward     : Forwards all children messages
                        flags: readable, writable
                        Boolean. Default: false
  mux-overhead        : Extra size overhead of muxing (0.02 = 2%)
                        flags: readable, writable, controllable
                        Double. Range:               0 -               1 Default:            0.02
  muxer               : The muxer element to use (NULL = default mp4mux). Valid only for async-finalize = FALSE
                        flags: readable, writable
                        Object of type "GstElement"
  muxer-factory       : The muxer element factory to use (default = mp4mux). Valid only for async-finalize = TRUE
                        flags: readable, writable
                        String. Default: "mp4mux"
  muxer-pad-map       : A GstStructure specifies the mapping from splitmuxsink sink pads to muxer pads
                        flags: readable, writable
                        Boxed pointer of type "GstStructure"
  muxer-preset        : The muxer preset to use. Valid only for async-finalize = TRUE
                        flags: readable, writable
                        String. Default: null
  muxer-properties    : The muxer element properties to use. Example: {properties,boolean-prop=true,string-prop="hi"}. Valid only for async-finalize = TRUE
                        flags: readable, writable
                        Boxed pointer of type "GstStructure"
  name                : The name of the object
                        flags: readable, writable, 0x2000
                        String. Default: "splitmuxsink0"
  parent              : The parent of the object
Factory Details:
  Rank                     none (0)
  Long-name                Split Muxing Bin
  Klass                    Generic/Bin/Muxer
  Description              Convenience bin that muxes incoming streams into multiple time/size limited files
  Author                   Jan Schmidt <jan@centricular.com>

Plugin Details:
  Name                     multifile
  Description              Reads/Writes buffers from/to sequentially named files
  Filename                 /usr/lib/gstreamer-1.0/libgstmultifile.so
  Version                  1.18.0
  License                  LGPL
  Source module            gst-plugins-good
  Source release date      2020-09-08
  Binary package           GStreamer Good Plug-ins source release
  Origin URL               Unknown package origin

GObject
 +----GInitiallyUnowned
       +----GstObject
             +----GstElement
                   +----GstBin
                         +----GstSplitMuxSink

Implemented Interfaces:
  GstChildProxy

Pad Templates:
  SINK template: 'caption_%u'
    Availability: On request
    Capabilities:
      ANY

  SINK template: 'subtitle_%u'
    Availability: On request
    Capabilities:
      ANY

  SINK template: 'audio_%u'
    Availability: On request
    Capabilities:
      ANY

  SINK template: 'video_aux_%u'
    Availability: On request
    Capabilities:
      ANY

  SINK template: 'video'
    Availability: On request
    Capabilities:
      ANY

Element has no clocking capabilities.
Element has no URI handling capabilities.

Pads:
  none

Element Properties:
  alignment-threshold : Allow non-reference streams to be that many ns before the reference stream
                        flags: readable, writable, changeable only in NULL or READY state
                        Unsigned Integer64. Range: 0 - 18446744073709551615 Default: 0
  async-finalize      : Finalize each fragment asynchronously and start a new one
                        flags: readable, writable
                        Boolean. Default: false
  async-handling      : The bin will handle Asynchronous state changes
                        flags: readable, writable
                        Boolean. Default: false
  location            : Format string pattern for the location of the files to write (e.g. video%05d.mp4)
                        flags: readable, writable
                        String. Default: null
  max-files           : Maximum number of files to keep on disk. Once the maximum is reached,old files start to be deleted to make room for new ones.
                        flags: readable, writable
                        Unsigned Integer. Range: 0 - 4294967295 Default: 0
  max-size-bytes      : Max. amount of data per file (in bytes, 0=disable)
                        flags: readable, writable, changeable only in NULL or READY state
                        Unsigned Integer64. Range: 0 - 18446744073709551615 Default: 0
  max-size-time       : Max. amount of time per file (in ns, 0=disable)
                        flags: readable, writable, changeable only in NULL or READY state
                        Unsigned Integer64. Range: 0 - 18446744073709551615 Default: 0
  max-size-timecode   : Maximum difference in timecode between first and last frame. Separator is assumed to be ":" everywhere (e.g. 01:00:00:00). Will only be effective if a timecode track is present.
                        flags: readable, writable, changeable only in NULL or READY state
                        String. Default: null
  message-forward     : Forwards all children messages
                        flags: readable, writable
                        Boolean. Default: false
  mux-overhead        : Extra size overhead of muxing (0.02 = 2%)
                        flags: readable, writable, controllable
                        Double. Range:               0 -               1 Default:            0.02
  muxer               : The muxer element to use (NULL = default mp4mux). Valid only for async-finalize = FALSE
                        flags: readable, writable
                        Object of type "GstElement"
  muxer-factory       : The muxer element factory to use (default = mp4mux). Valid only for async-finalize = TRUE
                        flags: readable, writable
                        String. Default: "mp4mux"
  muxer-pad-map       : A GstStructure specifies the mapping from splitmuxsink sink pads to muxer pads
                        flags: readable, writable
                        Boxed pointer of type "GstStructure"
  muxer-preset        : The muxer preset to use. Valid only for async-finalize = TRUE
                        flags: readable, writable
                        String. Default: null
  muxer-properties    : The muxer element properties to use. Example: {properties,boolean-prop=true,string-prop="hi"}. Valid only for async-finalize = TRUE
                        flags: readable, writable
                        Boxed pointer of type "GstStructure"
  name                : The name of the object
                        flags: readable, writable, 0x2000
                        String. Default: "splitmuxsink0"
  parent              : The parent of the object
                        flags: readable, writable, 0x2000
                        Object of type "GstObject"
  reset-muxer         : Reset the muxer after each segment. Disabling this will not work for most muxers.
                        flags: readable, writable
                        Boolean. Default: true
  send-keyframe-requests: Request a keyframe every max-size-time ns to try splitting at that point. Needs max-size-bytes to be 0 in order to be effective.
                        flags: readable, writable, changeable only in NULL or READY state
                        Boolean. Default: false
  sink                : The sink element (or element chain) to use (NULL = default filesink). Valid only for async-finalize = FALSE
                        flags: readable, writable
                        Object of type "GstElement"
  sink-factory        : The sink element factory to use (default = filesink). Valid only for async-finalize = TRUE
                        flags: readable, writable
                        String. Default: "filesink"
  sink-preset         : The sink preset to use. Valid only for async-finalize = TRUE
                        flags: readable, writable
                        String. Default: null
  sink-properties     : The sink element properties to use. Example: {properties,boolean-prop=true,string-prop="hi"}. Valid only for async-finalize = TRUE
                        flags: readable, writable
                        Boxed pointer of type "GstStructure"
  start-index         : Start value of fragment index.
                        flags: readable, writable
                        Integer. Range: 0 - 2147483647 Default: 0
  use-robust-muxing   : Check if muxers support robust muxing via the reserved-max-duration and reserved-duration-remaining properties and use them if so. (Only present on qtmux and mp4mux for now). splitmuxsink may then also  create new fragments if the reserved header space is about to overflow. Note that for mp4mux and qtmux, reserved-moov-update-period must be set manually by the app to a non-zero value for robust muxing to have an effect.
                        flags: readable, writable
                        Boolean. Default: false

Element Signals:
  "format-location" :  gchararray user_function (GstElement* object,
                                                 guint arg0,
                                                 gpointer user_data);
  "format-location-full" :  gchararray user_function (GstElement* object,
                                                      guint arg0,
                                                      GstSample* arg1,
                                                      gpointer user_data);
  "muxer-added" :  void user_function (GstElement* object,
                                       GstElement* arg0,
                                       gpointer user_data);
  "sink-added" :  void user_function (GstElement* object,
                                      GstElement* arg0,
                                      gpointer user_data);

Element Actions:
  "split-now" :  void user_function (GstElement* object);
  "split-after" :  void user_function (GstElement* object);
  "split-at-running-time" :  void user_function (GstElement* object,
                                                 guint64 arg0);
