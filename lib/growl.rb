# The Growl class provides a simple notification interface between ruby and the
# Growl (http://growl.info/) notification framework available for OSX.  If Growl
# is disabled, not installed, or not running on OSX then notifications fail back
# to $stdout.
#
# Usage: Create an instance of Growl passing configuration args to the
# constructor.  These include defaults for such things as notification icons,
# app name, notification name, etc.  See Growl#initialize for list of defaults
# and their reasonable default values if not specified (eg: default_app = base
# name of executing script $0).
#
# Once an instance of Growl has been instantiated, you can check the
# Growl#growl_enabled field to determine whether or not Growl is enabled on the
# current system.  If Growl is not enabled then calls to Growl#notify will
# continue to work - but will write to $stdout instead using the format:
# <notification>: <title>: <message>
#
# ==== Example
#
#     growl = Growl.new(
#         :default_app => "ClamAV Scan Report", 
#         :default_title => "ClamAV", 
#         :default_image_type => :image_file, 
#         :default_image => "images/notify.gif"
#     )
#     growl.notify("Updating definitions", :title => "FreshClam")
#     freshclam()
#     growl.notify("Scan started")
#     scan()
#     growl.notify("Scan completed")
module GrowlRubyApi
  class Growl

    attr_accessor :default_app, :default_title, :all_notifications, :enabled_notifications, :default_notification, :default_image_type, :default_image
    attr_reader :growl_enabled

    # call-seq:
    #   Growl.new() => Growl instance configured with default defaults
    #   Growl.new(:default_app => "My Cool App") => Growl instance with custom default app name
    #
    # Constructs a new instance of Growl configuring the following growl registration 
    # attributes and defaults via an options hash.  After configuring the attributes
    # and default fields, they are used to register an application with Growl.
    #
    # ==== Options
    #
    # * <tt>:default_app</tt> - default application name
    #     assigns @default_app to name that represents this
    #     application as it appears in Growl pref pane.  Specifying a :default_app
    #     will register it in the Growl pref pane if not already registered.  This
    #     app name will be used by the Growl#notify() method if :app option is not
    #     specified.  If no value specified then :default_app defaults to basename
    #     of current executing script (eg: clamav.rb)
    # * <tt>:default_title</tt> - default notification title
    #     assigns @default_title to the default title to
    #     be used by Growl#notify() method if one is not specified in the :title
    #     option.  Defaults to @default_app name if not specified.
    #     The title generally appears at the top of every Growl notification style.
    # * <tt>:all_notifications</tt> - list of all notification type names
    #     assigns @all_notifications to list of all
    #     notifications to be registered with Growl.  Growl lets each of the
    #     registered notifications be configured with a different style and
    #     options.  If no value specified then :all_notifications defaults to
    #     ["Notify"].
    # * <tt>:enabled_notifications</tt> - list of enabled notification type names
    #     assigns @enabled_notifications to list
    #     of notifications (subset of :all_notifications) to be enabled by Growl.
    #     If no value specified then :enabled_notifications defaults to all items
    #     in :all_notifications list.
    # * <tt>:default_notification</tt> - default notification type name
    #     assigns @default_notification to default
    #     notification name to be used by Growl#notify() method if :notification
    #     option is not specified.  If no value specified then
    #     :default_notification defaults to first item in @enabled_notifications
    #     list.
    # * <tt>:default_image_type</tt> - default notification image type
    #     assigns @default_image_type to one of
    #     (:none, :app_icon, :file_icon, :image_file).  This value is used
    #     with the @default_image value to specify the default image to be
    #     displayed by Growl#notify if no :image_type option is specified.
    #     :app_icon means that :default_image will be interpreted as an
    #     application name (eg: mail.app).  :file_icon means that :default_image
    #     will be interpreted as a path to a file whose finder icon will be used.
    #     :image_file means that :default_image will be interpreted as the path
    #     to an image files (eg: images/notify.png).  If no value is specified
    #     then @default_image_type defaults to :none.
    # * <tt>:default_image</tt> - default notification image specifier
    #     assigns @default_image to either an app name,
    #     file path, or image path depending on the value of @default_image_type.
    #     This value is used by Growl#notify() method if not :image option is
    #     specified.  If no value is specified then @default_image defaults to
    #     nil - meaning that no image will be displayed by default in the Growl
    #     notifications.
    def initialize(options = {})
      @default_app = options[:default_app] || Pathname($0).basename
      @default_title = options[:default_title] || @default_app
      @all_notifications = options[:all_notifications] || ["Notify"]
      @enabled_notifications = options[:enabled_notifications] || @all_notifications
      @default_notification = options[:default_notification] || @enabled_notifications.first
      @default_image_type = options[:default_image_type] || :none
      @default_image = options[:default_image]
      unless @all_notifications.include?(@default_notification)
        raise ArgumentError, ":default_notification must be a member of :all_notifications"
      end
      register
    end


    # call-seq:
    #   Growl.register() => Register with Growl using the defaults specified in
    #                       the constructor's options
    #   Growl.register(:app => "Another Cool App") => Register with Growl
    #
    # Manually registers another application with Growl in addition to the
    # registration performed by the constructor using all the attribute and
    # default fields.  This method also assigns the value of @growl_enabled
    # field depending upon whether or not communication could be established with
    # the Growl framework.
    #
    # ==== Options
    #
    # * <tt>:app</tt> - application name to be registered
    #     if :app option is not specified then value of @default_app field is used
    # * <tt>:all_notifications</tt> - list of all notification names to be registered
    #     if :all_notifications option is not specified then value of
    #     @all_notifications field is used.
    # * <tt>:enabled_notifications</tt> - list of enabled notification names to be registered
    #     Must be a subset of :all_notifications
    #     if :enabled_notifications option is not specified then value of
    #     @enabled_notifications field is used.
    # * <tt>:image_type</tt> - notification image type to be registered
    #     Growl will use :image_type with :image to register a default application
    #     to be associated with all notifications for the specified :app unless 
    #     overridden in the Growl#notify() method's options.
    #     Any value other than :app_icon will be ignored since only an icon of 
    #     an application may be registered to be associated with the :app.
    #     If :image_type option is not specified then value of @default_image_type
    #     is used.  If one of (:none, :file_icon, :image_file) is resolved from
    #     :image_type or @default_image_type then no image is registered - but 
    #     @default_image_type will still be used on each call to Growl#notify().
    # * <tt>:image</tt> - notification image specifier to be registered
    #     Growl will use :image_type with :image to register a default application
    #     to be associated with all notifications for the specified :app unless 
    #     overridden in the Growl#notify() method's options.
    #     Since only :app_icon is allowed for :image_type option, :image must 
    #     represent an app name if provided.  If :image option is not specified
    #     then value of @default_image is used.  Note that this value will be 
    #     ignored if :image_type option value is not :app_icon - but 
    #     @default_image will still be used on each call to Growl#notify().
    def register(options = {})
      options = {
          :app => @default_app,
          :all_notifications => @all_notifications,
          :enabled_notifications => @enabled_notifications,
          :image_type => @default_image_type,
          :image => @default_image
      }.merge!(options)
      unless options[:all_notifications].size > 0
        raise ArgumentError, ":all_notifications must not be empty"
      end
      unless options[:enabled_notifications].all?{|obj| options[:all_notifications].include?(obj)}
        raise ArgumentError, ":enabled_notifications must be a subset of :all_notifications"
      end
      @growl_enabled = applescript('tell application "System Events" to get count of (every process whose name is "GrowlHelperApp")').to_i > 0
      if @growl_enabled
        applescript(<<-ARG)
  			tell application "GrowlHelperApp"
  				register as application "#{options[:app]}" \
  					all notifications {"#{options[:all_notifications].join('","')}"} \
  					default notifications {"#{options[:enabled_notifications].join('","')}"} \
  					#{image_syntax(options[:image_type], options[:image]) if options[:image_type] == :app_icon}
  			end tell
        ARG
      else
        $stderr.puts("Could not setup growl notifications because growl is not active.  Failing back to $stdout (console).")
      end
    end


    # call-seq:
    #   Growl.notify("message") => Display a Growl notification
    #   Growl.notify("message", :title => "Alert") => Display a Growl notification
    #       specifying a custom title
    #
    # Display 'message' as a Growl notification with the specified 'options'.
    #
    # ==== Options
    #
    # * <tt>:title</tt> - title to associate with this notify
    #     The title text usually appears in the Growl notification in addition 
    #     to the 'message' text.  If :title option is not specified then the 
    #     value of @default_title field is used.
    # * <tt>:notification</tt> - notification name to associate with this notify
    #     Growl will use this in combination with :app to determine the 
    #     registered configuration to be used to display the notification.  The 
    #     notification name must be a member of @all_notifications.  If 
    #     :notification is not specified then value of @default_notification 
    #     field is used.
    # * <tt>:app</tt> - application name to associate with this notify
    #     Growl will use this in combination with :notification to determine the
    #     registered configuration to be used to display the notification.
    #     if :app option is not specified then value of @default_app field is 
    #     used.
    # * <tt>:image_type</tt> - specifies whether :image is an app or file icon or an image path
    #     :image_type must be one of (:none, :app_icon, :file_icon, :image_file).  
    #     This value is used in combination with :image option to specify a 
    #     custom image for this specific notification.  If no :image_type is
    #     provided then @default_image_type is used.  If a @default_image_type
    #     and @default_image is defined but you explicitly don't want an image 
    #     to be displayed for this specific notification then pass :none for
    #     :image_type option.
    # * <tt>:image</tt> - application name or file path depending on :image_type
    #     If :image_type is :app_icon then :image specifies the name of the 
    #     application whose icon should be displayed for this specific 
    #     notification (eg: "iTunes.app").  If :image_type is :file_icon then 
    #     :image specifies the path to a file whose icon should be displayed 
    #     (eg: "docs/word/report.docx").  If :image_type is :image_file then 
    #     :image specifies the path to an image file to be displayed (eg: 
    #     images/alert.png)
    # * <tt>:priority</tt> - priority for this notification (-2, -1, 0, 1, 2)
    # * <tt>:sticky</tt> - if true then this notification remains on the screen
    def notify(message, options = {})
      options = {
        :title => @default_title,
        :notification => @default_notification,
        :app => @default_app,
        :image_type => @default_image_type,
        :image => @default_image,
        :priority => 0,
        :sticky => false
      }.merge!(options)
      unless @all_notifications.include?(options[:notification])
        raise ArgumentError, ":notification must be a member of @all_notifications"
      end
      unless [:none, :app_icon, :file_icon, :image_file].include?(options[:image_type])
        raise ArgumentError, ":image_type must be one of [:none, :app_icon, :file_icon, :image_file]"
      end
      unless (-2..2).include?(options[:priority])
        raise ArgumentError, ":priority must be between -2 and 2 inclusive"
      end
      if @growl_enabled
        applescript(<<-ARG)
        tell application "GrowlHelperApp"
          notify with name "#{options[:notification]}" \
            title "#{options[:title]}" \
            description "#{message}" \
            application name "#{options[:app]}" \
            #{"sticky \"yes\"" if options[:sticky]} \
            #{"priority #{options[:priority]}" if options[:priority]} \
            #{image_syntax(options[:image_type], options[:image])}
        end tell
        ARG
      else
        puts("#{options[:notification]}: #{title}: #{message}")
      end
    end


    # Utility methods -----------------------------------------------------------
    def applescript(script)
      `/usr/bin/osascript <<EOSCRIPT\n#{script}\nEOSCRIPT`
    end


    def image_syntax(image_type, image)
      return "" unless image
      case image_type
        when :app_icon then "icon of application \"#{image}\""
        when :file_icon then "icon of file \"#{image}\""
        when :image_file then "image from location \"#{image}\"" # supported types: BMP, GIF, ICNS, ICO, JPEG, JPEG 2000, PNG, PSD, TGA, TIFF
        else ""
      end
    end

  end
end