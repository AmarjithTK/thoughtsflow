#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  GtkWindow* window;
  FlMethodChannel* desktop_channel;
  GCancellable* quit_cancellable;
  GtkStatusIcon* status_icon;
  GtkWidget* tray_menu;
  gboolean background_enabled;
  gboolean always_on_top;
  gboolean iconified;
  gboolean initial_size_pending;
  gboolean quit_requested;
  gboolean quitting;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static void quit_application(MyApplication* self);
static void request_quit(MyApplication* self);

static gboolean window_hidden(MyApplication* self) {
  return self->window != nullptr &&
         (!gtk_widget_get_visible(GTK_WIDGET(self->window)) || self->iconified);
}

static void show_window(MyApplication* self) {
  if (self->window == nullptr || self->quitting) {
    return;
  }
  g_message("[UI] Presenting desktop window");
  gtk_widget_show(GTK_WIDGET(self->window));
  gtk_window_deiconify(self->window);
  gtk_window_present(self->window);
}

// Legacy GTK trays are optional: some Wayland/GNOME desktops do not embed them.
// Application activation remains a recovery path when there is no tray host.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
static void update_tray_visibility(MyApplication* self) {
  if (self->status_icon != nullptr) {
    gtk_status_icon_set_visible(
        self->status_icon,
        !self->quitting && (self->background_enabled || window_hidden(self)));
  }
}

static void tray_open_cb(GtkMenuItem* item, MyApplication* self) {
  show_window(self);
}

static void tray_quit_cb(GtkMenuItem* item, MyApplication* self) {
  request_quit(self);
}

static void tray_activate_cb(GtkStatusIcon* icon, MyApplication* self) {
  show_window(self);
}

static void tray_popup_cb(GtkStatusIcon* icon,
                          guint button,
                          guint32 activate_time,
                          MyApplication* self) {
  gtk_menu_popup(GTK_MENU(self->tray_menu), nullptr, nullptr,
                 gtk_status_icon_position_menu, icon, button, activate_time);
}

static void create_tray(MyApplication* self) {
#ifdef GDK_WINDOWING_X11
  if (!GDK_IS_X11_DISPLAY(gdk_display_get_default())) {
    return;
  }
#else
  return;
#endif
  const gchar* icon_name =
      gtk_icon_theme_has_icon(gtk_icon_theme_get_default(), "solasflow")
          ? "solasflow"
          : "appointment-soon";
  self->status_icon = gtk_status_icon_new_from_icon_name(icon_name);
  gtk_status_icon_set_title(self->status_icon, "Solas Flow");
  gtk_status_icon_set_tooltip_text(self->status_icon, "Solas Flow");
  gtk_status_icon_set_visible(self->status_icon, FALSE);
  g_signal_connect(self->status_icon, "activate", G_CALLBACK(tray_activate_cb),
                   self);
  g_signal_connect(self->status_icon, "popup-menu", G_CALLBACK(tray_popup_cb),
                   self);

  self->tray_menu = gtk_menu_new();
  g_object_ref_sink(self->tray_menu);
  GtkWidget* open_item = gtk_menu_item_new_with_label("Open");
  GtkWidget* quit_item = gtk_menu_item_new_with_label("Quit");
  gtk_menu_shell_append(GTK_MENU_SHELL(self->tray_menu), open_item);
  gtk_menu_shell_append(GTK_MENU_SHELL(self->tray_menu), quit_item);
  g_signal_connect(open_item, "activate", G_CALLBACK(tray_open_cb), self);
  g_signal_connect(quit_item, "activate", G_CALLBACK(tray_quit_cb), self);
  gtk_widget_show_all(self->tray_menu);
}

static void clear_tray(MyApplication* self) {
  if (self->status_icon != nullptr) {
    gtk_status_icon_set_visible(self->status_icon, FALSE);
    g_clear_object(&self->status_icon);
  }
  if (self->tray_menu != nullptr) {
    gtk_widget_destroy(self->tray_menu);
    g_clear_object(&self->tray_menu);
  }
}
#pragma GCC diagnostic pop

static void visibility_changed_cb(GtkWidget* window, MyApplication* self) {
  g_message("[STATE] Desktop window hidden=%s",
            window_hidden(self) ? "true" : "false");
  update_tray_visibility(self);
  if (self->desktop_channel != nullptr && !self->quitting) {
    g_autoptr(FlValue) hidden = fl_value_new_bool(window_hidden(self));
    fl_method_channel_invoke_method(self->desktop_channel, "visibilityChanged",
                                   hidden, nullptr, nullptr, nullptr);
  }
}

static gboolean window_state_cb(GtkWidget* window,
                                GdkEventWindowState* event,
                                MyApplication* self) {
  if ((event->changed_mask & GDK_WINDOW_STATE_ICONIFIED) != 0) {
    self->iconified =
        (event->new_window_state & GDK_WINDOW_STATE_ICONIFIED) != 0;
    visibility_changed_cb(window, self);
  }
  return FALSE;
}

static void clear_desktop_channel(MyApplication* self) {
  if (self->quit_cancellable != nullptr) {
    g_cancellable_cancel(self->quit_cancellable);
    g_clear_object(&self->quit_cancellable);
  }
  if (self->desktop_channel != nullptr) {
    fl_method_channel_set_method_call_handler(self->desktop_channel, nullptr,
                                             nullptr, nullptr);
    g_clear_object(&self->desktop_channel);
  }
}

static void window_destroy_cb(GtkWidget* window, MyApplication* self) {
  self->window = nullptr;
  clear_desktop_channel(self);
}

static void quit_application(MyApplication* self) {
  if (self->quitting) {
    return;
  }
  self->quitting = TRUE;
  g_message("[APP] Shutting down desktop application");
  clear_tray(self);
  if (self->window != nullptr) {
    gtk_widget_destroy(GTK_WIDGET(self->window));
  }
  g_application_quit(G_APPLICATION(self));
}

static void quit_requested_cb(GObject* object,
                              GAsyncResult* result,
                              gpointer user_data) {
  g_autoptr(MyApplication) self = MY_APPLICATION(user_data);
  g_autoptr(GError) error = nullptr;
  g_autoptr(FlMethodResponse) response =
      fl_method_channel_invoke_method_finish(FL_METHOD_CHANNEL(object), result,
                                           &error);
  if (self->quitting) {
    return;
  }
  FlValue* handled =
      response != nullptr ? fl_method_response_get_result(response, &error)
                          : nullptr;
  if (handled == nullptr || fl_value_get_type(handled) != FL_VALUE_TYPE_BOOL ||
      !fl_value_get_bool(handled)) {
    // A close before Dart has initialized must still be able to exit.
    quit_application(self);
  }
}

static void request_quit(MyApplication* self) {
  if (self->quitting || self->quit_requested) {
    return;
  }
  self->quit_requested = TRUE;
  if (self->desktop_channel == nullptr) {
    quit_application(self);
    return;
  }
  // Dart flushes settings and disposes speech before calling the final quit.
  fl_method_channel_invoke_method(
      self->desktop_channel, "quitRequested", nullptr, self->quit_cancellable,
      quit_requested_cb, g_object_ref(self));
}

static gboolean window_delete_cb(GtkWidget* window,
                                 GdkEvent* event,
                                 MyApplication* self) {
  g_message("[UI] Desktop close background=%s",
            self->background_enabled ? "true" : "false");
  if (self->background_enabled && !self->quitting) {
    gtk_widget_hide(window);
  } else {
    request_quit(self);
  }
  return TRUE;
}

static GdkMonitor* window_monitor(GtkWindow* window) {
  GdkDisplay* display = gtk_widget_get_display(GTK_WIDGET(window));
  GdkWindow* surface = gtk_widget_get_window(GTK_WIDGET(window));
  GdkMonitor* monitor =
      surface != nullptr ? gdk_display_get_monitor_at_window(display, surface)
                         : gdk_display_get_primary_monitor(display);
  if (monitor == nullptr && gdk_display_get_n_monitors(display) > 0) {
    monitor = gdk_display_get_monitor(display, 0);
  }
  return monitor;
}

static void initial_window_size(GtkWindow* window, gboolean include_frame) {
  GdkMonitor* monitor = window_monitor(window);
  if (monitor == nullptr) {
    gtk_window_set_default_size(window, 400, 860);
    return;
  }
  GdkRectangle workarea;
  gdk_monitor_get_workarea(monitor, &workarea);
  const gint outer_width = MIN(400, MAX(1, workarea.width - 32));
  const gint outer_height = MIN(860, MAX(1, workarea.height - 32));
  gint frame_width = 0;
  gint frame_height = 0;
  GdkWindow* surface = gtk_widget_get_window(GTK_WIDGET(window));
  if (include_frame && surface != nullptr) {
    GdkRectangle frame;
    gdk_window_get_frame_extents(surface, &frame);
    gint width;
    gint height;
    gtk_window_get_size(window, &width, &height);
    frame_width = MAX(0, frame.width - width);
    frame_height = MAX(0, frame.height - height);
  }
  const gint width = MAX(1, outer_width - frame_width);
  const gint height = MAX(1, outer_height - frame_height);
  if (include_frame) {
    gtk_window_resize(window, width, height);
    // Wayland compositors own positioning and may ignore this request.
    gtk_window_move(window, workarea.x + (workarea.width - outer_width) / 2,
                    workarea.y + (workarea.height - outer_height) / 2);
  } else {
    gtk_window_set_default_size(window, width, height);
    gtk_window_set_position(window, GTK_WIN_POS_CENTER);
  }
  // Deliberately no maximum geometry hints: landscape/fullscreen stay usable.
}

static gboolean initial_configure_cb(GtkWidget* window,
                                     GdkEvent* event,
                                     MyApplication* self) {
  if (self->initial_size_pending && gtk_widget_get_mapped(window)) {
    self->initial_size_pending = FALSE;
    initial_window_size(GTK_WINDOW(window), TRUE);
  }
  return FALSE;
}

static gboolean is_value_type(FlValue* value, FlValueType type) {
  return value != nullptr && fl_value_get_type(value) == type;
}

static FlMethodResponse* invalid_arguments(const gchar* message) {
  return FL_METHOD_RESPONSE(
      fl_method_error_response_new("invalid-arguments", message, nullptr));
}

static void desktop_method_call_cb(FlMethodChannel* channel,
                                   FlMethodCall* method_call,
                                   gpointer user_data) {
  MyApplication* self = MY_APPLICATION(user_data);
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;
  gboolean quit_after_response = FALSE;

  if (g_strcmp0(method, "configure") == 0) {
    FlValue* background = is_value_type(args, FL_VALUE_TYPE_MAP)
                              ? fl_value_lookup_string(args, "background")
                              : nullptr;
    FlValue* top = is_value_type(args, FL_VALUE_TYPE_MAP)
                       ? fl_value_lookup_string(args, "alwaysOnTop")
                       : nullptr;
    if (!is_value_type(background, FL_VALUE_TYPE_BOOL) ||
        !is_value_type(top, FL_VALUE_TYPE_BOOL) ||
        fl_value_get_length(args) != 2) {
      response = invalid_arguments(
          "configure requires background and alwaysOnTop booleans.");
    } else {
      self->background_enabled = fl_value_get_bool(background);
      self->always_on_top = fl_value_get_bool(top);
      g_message("[STATE] Desktop background=%s alwaysOnTop=%s",
                self->background_enabled ? "true" : "false",
                self->always_on_top ? "true" : "false");
      // This is a window-manager hint, not a guarantee on Wayland.
      gtk_window_set_keep_above(self->window, self->always_on_top);
      if (!self->background_enabled &&
          !gtk_widget_get_visible(GTK_WIDGET(self->window))) {
        show_window(self);
      }
      update_tray_visibility(self);
      g_autoptr(FlValue) hidden = fl_value_new_bool(window_hidden(self));
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(hidden));
    }
  } else if (g_strcmp0(method, "fullscreen") == 0) {
    if (!is_value_type(args, FL_VALUE_TYPE_BOOL)) {
      response = invalid_arguments("fullscreen requires a boolean.");
    } else {
      if (fl_value_get_bool(args)) {
        gtk_window_fullscreen(self->window);
      } else {
        gtk_window_unfullscreen(self->window);
      }
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    }
  } else if (g_strcmp0(method, "notify") == 0) {
    FlValue* title = is_value_type(args, FL_VALUE_TYPE_MAP)
                         ? fl_value_lookup_string(args, "title")
                         : nullptr;
    FlValue* body = is_value_type(args, FL_VALUE_TYPE_MAP)
                        ? fl_value_lookup_string(args, "body")
                        : nullptr;
    if (!is_value_type(title, FL_VALUE_TYPE_STRING) ||
        !is_value_type(body, FL_VALUE_TYPE_STRING) ||
        fl_value_get_length(args) != 2) {
      response =
          invalid_arguments("notify requires title and body strings.");
    } else {
      g_autoptr(GNotification) notification =
          g_notification_new(fl_value_get_string(title));
      g_notification_set_body(notification, fl_value_get_string(body));
      g_notification_set_default_action(notification, "app.open");
      g_notification_add_button(notification, "Open", "app.open");
      g_application_send_notification(G_APPLICATION(self), "solasflow-status",
                                       notification);
      g_message("[UI] Desktop notification queued");
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    }
  } else if (g_strcmp0(method, "hide") == 0 ||
             g_strcmp0(method, "show") == 0 ||
             g_strcmp0(method, "quit") == 0) {
    if (args != nullptr && fl_value_get_type(args) != FL_VALUE_TYPE_NULL) {
      response = invalid_arguments("hide, show and quit take no arguments.");
    } else {
      if (g_strcmp0(method, "hide") == 0) {
        gtk_widget_hide(GTK_WIDGET(self->window));
      } else if (g_strcmp0(method, "show") == 0) {
        show_window(self);
      } else {
        quit_after_response = TRUE;
      }
      response = FL_METHOD_RESPONSE(fl_method_success_response_new(nullptr));
    }
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  g_autoptr(GError) error = nullptr;
  if (!fl_method_call_respond(method_call, response, &error)) {
    g_warning("Failed to respond on desktop channel: %s", error->message);
  }
  if (quit_after_response) {
    quit_application(self);
  }
}

static void open_action_cb(GSimpleAction* action,
                           GVariant* parameter,
                           MyApplication* self) {
  g_application_activate(G_APPLICATION(self));
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  g_message("[APP] First desktop frame rendered");
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  if (self->window != nullptr) {
    show_window(self);
    return;
  }
  if (self->quitting) {
    return;
  }
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  self->window = window;
  self->initial_size_pending = TRUE;
  g_signal_connect(window, "delete-event", G_CALLBACK(window_delete_cb), self);
  g_signal_connect(window, "destroy", G_CALLBACK(window_destroy_cb), self);
  g_signal_connect(window, "show", G_CALLBACK(visibility_changed_cb), self);
  g_signal_connect(window, "hide", G_CALLBACK(visibility_changed_cb), self);
  g_signal_connect(window, "window-state-event", G_CALLBACK(window_state_cb),
                   self);
  g_signal_connect(window, "map-event", G_CALLBACK(initial_configure_cb), self);
  g_signal_connect(window, "configure-event", G_CALLBACK(initial_configure_cb),
                   self);
  create_tray(self);

  // Use a header bar when running in GNOME as this is the common style used
  // by applications and is the setup most users will be using (e.g. Ubuntu
  // desktop).
  // If running on X and not using GNOME then just use a traditional title bar
  // in case the window manager does more exotic layout, e.g. tiling.
  // If running on Wayland assume the header bar will work (may need changing
  // if future cases occur).
  gboolean use_header_bar = TRUE;
#ifdef GDK_WINDOWING_X11
  GdkScreen* screen = gtk_window_get_screen(window);
  if (GDK_IS_X11_SCREEN(screen)) {
    const gchar* wm_name = gdk_x11_screen_get_window_manager_name(screen);
    if (g_strcmp0(wm_name, "GNOME Shell") != 0) {
      use_header_bar = FALSE;
    }
  }
#endif
  if (use_header_bar) {
    GtkHeaderBar* header_bar = GTK_HEADER_BAR(gtk_header_bar_new());
    gtk_widget_show(GTK_WIDGET(header_bar));
    gtk_header_bar_set_title(header_bar, "Solas Flow");
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "Solas Flow");
  }
  gtk_window_set_icon_name(window, "solasflow");

  initial_window_size(window, FALSE);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  // Background defaults to black, override it here if necessary, e.g. #00000000
  // for transparent.
  gdk_rgba_parse(&background_color, "#000000");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->desktop_channel = fl_method_channel_new(
      fl_engine_get_binary_messenger(fl_view_get_engine(view)),
      "com.atherpulse.solasflow/desktop", FL_METHOD_CODEC(codec));
  self->quit_cancellable = g_cancellable_new();
  fl_method_channel_set_method_call_handler(
      self->desktop_channel, desktop_method_call_cb, self, nullptr);

  // Map before rendering: a saved background preference must not leave a cold
  // launch waiting for its first frame in an unmapped window.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_show(GTK_WIDGET(window));
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  // Strip out the first argument as it is the binary name.
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
  g_autoptr(GSimpleAction) open_action = g_simple_action_new("open", nullptr);
  g_signal_connect(open_action, "activate", G_CALLBACK(open_action_cb),
                   application);
  g_action_map_add_action(G_ACTION_MAP(application), G_ACTION(open_action));
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  self->quitting = TRUE;
  clear_desktop_channel(self);
  clear_tray(self);
  g_application_withdraw_notification(application, "solasflow-status");
  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  clear_desktop_channel(self);
  clear_tray(self);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {}

MyApplication* my_application_new() {
  // Set the program name to the application ID, which helps various systems
  // like GTK and desktop environments map this running application to its
  // corresponding .desktop file. This ensures better integration by allowing
  // the application to be recognized beyond its binary name.
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     static_cast<GApplicationFlags>(0),
                                     nullptr));
}
