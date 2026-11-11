"""A silent close needs an explanation. These tests keep the breadcrumb recorder, the memory answer and
the web-process recovery wired, and keep force unwraps out of the row paths."""
import pathlib
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]


def read(name):
    return (ROOT / name).read_text(encoding='utf-8')


class CrashDiagnostics(unittest.TestCase):
    def test_recorder_is_installed_before_anything_else(self):
        log = read('App/CrashLog.swift')
        self.assertIn('static func install()', log)
        self.assertIn('NSSetUncaughtExceptionHandler', log)
        for signal_name in ['SIGABRT', 'SIGSEGV', 'SIGILL', 'SIGFPE', 'SIGBUS', 'SIGTRAP']:
            self.assertIn(signal_name, log)
        self.assertIn('static func tail(', log)
        self.assertIn('static func note(', log)
        delegate = read('App/Downloads.swift')
        launch = delegate.split('didFinishLaunchingWithOptions', 1)[1].split('return true', 1)[0]
        self.assertIn('CrashLog.install()', launch, 'the recorder must exist before a crash can happen')

    def test_signal_handler_stays_allocation_free(self):
        log = read('App/CrashLog.swift')
        handler = log.split('private func kontytCrashHandler', 1)[1]
        for forbidden in ['String(', 'FileHandle', 'print(', 'NSLog']:
            self.assertNotIn(forbidden, handler, f'{forbidden} is not safe inside a signal handler')
        self.assertIn('write(descriptor', handler)

    def test_settings_can_show_and_copy_the_trace(self):
        settings = read('App/StudioViews.swift')
        self.assertIn('diagnosticsSection', settings)
        self.assertIn('CrashLog.tail(', settings)
        self.assertIn('CrashLog.clear()', settings)
        self.assertIn('Analiz Verileri', settings, 'the system report is the authoritative source')

    def test_memory_warning_frees_the_caches_but_not_the_files(self):
        library = read('App/KontYTApp.swift')
        self.assertIn('func handleMemoryWarning()', library)
        body = library.split('func handleMemoryWarning()', 1)[1].split('func clearCaches', 1)[0]
        self.assertIn('artworkCache.removeAll()', body)
        self.assertNotIn('removeItem', body, 'a warning must never delete media or caches on disk')
        root = read('App/StudioViews.swift')
        self.assertIn('didReceiveMemoryWarningNotification', root)

    def test_web_process_termination_recovers_once(self):
        browser = read('App/YouTubeBrowser.swift')
        self.assertIn('func webViewWebContentProcessDidTerminate(_ webView: WKWebView)', browser)
        self.assertIn('webProcessReloads < 1', browser)
        self.assertIn('webView.reload()', browser)

    def test_list_rows_cannot_kill_the_app_on_a_bad_id(self):
        collections = read('App/Collections.swift')
        self.assertNotIn('return components.url!', collections)
        self.assertIn('?? URL(string: "https://www.youtube.com/")', collections)


if __name__ == '__main__':
    unittest.main()
