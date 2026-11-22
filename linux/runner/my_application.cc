#include "my_application.h"

#include <flutter_linux/flutter_linux.h>
#ifdef GDK_WINDOWING_X11
#include <gdk/gdkx.h>
#endif

#include "flutter/generated_plugin_registrant.h"

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Resolves <executable_dir>/data/icon.png if present; caller owns returned string.
static gchar* get_bundled_icon_path() {
  g_autofree gchar* exe_path = g_file_read_link("/proc/self/exe", nullptr);
  if (exe_path == nullptr) {
    return nullptr;
  }
  g_autofree gchar* exe_dir = g_path_get_dirname(exe_path);
  gchar* icon_path = g_build_filename(exe_dir, "data", "icon.png", nullptr);
  if (!g_file_test(icon_path, G_FILE_TEST_EXISTS)) {
    g_free(icon_path);
    return nullptr;
  }
  return icon_path;
}

// Applies a modern GNOME / Libadwaita flat minimalist style to Ubuntu's GtkHeaderBar.
// Uses GTK semantic color variables so it adapts automatically to light & dark themes.
static void apply_libadwaita_header_bar_style(GtkWindow* window,
                                              GtkHeaderBar* header_bar) {
  gtk_style_context_add_class(
      gtk_widget_get_style_context(GTK_WIDGET(header_bar)),
      "adw-flat-headerbar");

  static gboolean css_registered = FALSE;
  if (css_registered) {
    return;
  }

  static const gchar* kLibadwaitaHeaderBarCss =
      "headerbar.adw-flat-headerbar,"
      "headerbar.adw-flat-headerbar.titlebar {"
      "  min-height: 28px;"
      "  padding: 2px 10px;"
      "  background-image: none;"
      "  background-color: @theme_bg_color;"
      "  color: @theme_fg_color;"
      "  border: none;"
      "  border-bottom: 1px solid alpha(@theme_fg_color, 0.10);"
      "  box-shadow: none;"
      "}"
      "headerbar.adw-flat-headerbar:backdrop,"
      "headerbar.adw-flat-headerbar.titlebar:backdrop {"
      "  background-image: none;"
      "  background-color: @theme_bg_color;"
      "  color: alpha(@theme_fg_color, 0.55);"
      "  border-bottom: 1px solid alpha(@theme_fg_color, 0.06);"
      "  box-shadow: none;"
      "}"
      "headerbar.adw-flat-headerbar .title {"
      "  font-size: 22px;"
      "  font-weight: 700;"
      "  letter-spacing: 0.2px;"
      "  padding: 0;"
      "}"
      "headerbar.adw-flat-headerbar button,"
      "headerbar.adw-flat-headerbar button.titlebutton {"
      "  min-height: 22px;"
      "  min-width: 22px;"
      "  margin: 0 2px;"
      "  padding: 2px;"
      "  border-radius: 999px;"
      "  border: none;"
      "  box-shadow: none;"
      "  background-image: none;"
      "  background-color: transparent;"
      "  color: alpha(@theme_fg_color, 0.85);"
      "  transition: background-color 140ms ease, color 140ms ease;"
      "}"
      "headerbar.adw-flat-headerbar button.titlebutton:hover {"
      "  background-color: alpha(@theme_fg_color, 0.10);"
      "  color: @theme_fg_color;"
      "}"
      "headerbar.adw-flat-headerbar button.titlebutton:active {"
      "  background-color: alpha(@theme_fg_color, 0.16);"
      "}"
      "headerbar.adw-flat-headerbar button.titlebutton.close:hover {"
      "  background-color: #e01b24;"
      "  color: #ffffff;"
      "}"
      "headerbar.adw-flat-headerbar button.titlebutton.close:active {"
      "  background-color: #c01c28;"
      "  color: #ffffff;"
      "}"
      "headerbar.adw-flat-headerbar button.titlebutton:backdrop {"
      "  color: alpha(@theme_fg_color, 0.45);"
      "}";

  GtkCssProvider* css_provider = gtk_css_provider_new();
  g_autoptr(GError) error = nullptr;
  if (gtk_css_provider_load_from_data(css_provider, kLibadwaitaHeaderBarCss, -1,
                                      &error)) {
    GdkScreen* screen = gtk_window_get_screen(window);
    if (screen != nullptr) {
      gtk_style_context_add_provider_for_screen(
          screen, GTK_STYLE_PROVIDER(css_provider),
          GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
      css_registered = TRUE;
    }
  } else if (error != nullptr) {
    g_warning("Failed to load Libadwaita header bar CSS: %s", error->message);
  }
  g_object_unref(css_provider);
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);
  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));

  g_autofree gchar* icon_path = get_bundled_icon_path();
  if (icon_path != nullptr) {
    gtk_window_set_icon_from_file(window, icon_path, nullptr);
  }

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
    gtk_header_bar_set_title(header_bar, "VideoToolKit");
    gtk_header_bar_set_has_subtitle(header_bar, FALSE);
    gtk_header_bar_set_show_close_button(header_bar, TRUE);
    apply_libadwaita_header_bar_style(window, header_bar);
    gtk_window_set_titlebar(window, GTK_WIDGET(header_bar));
  } else {
    gtk_window_set_title(window, "VideoToolKit");
  }

  gtk_window_set_default_size(window, 1280, 720);

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

  // Show the window when Flutter renders.
  // Requires the view to be realized so we can start rendering.
  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
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
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application startup.

  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  // MyApplication* self = MY_APPLICATION(object);

  // Perform any actions required at application shutdown.

  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
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
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
