using Microsoft.UI.Xaml.Controls;

namespace Skybridge.WinClient.Settings;

// SettingsAdvancedView — Tab 8 (高级 / Advanced) code-behind.
//
// No code-behind logic is required: every interactive control in the XAML two-way binds directly
// to {Binding Settings.<Prop>, Mode=TwoWay} on the SettingsCoordinator (exposed as
// SessionViewModel.Settings, inherited as this UserControl's DataContext from SettingsView →
// MainWindow RootShell). The coordinator owns persistence + the live-effect dispatch, so the view
// stays purely declarative. LOCKED-STATUS / OMIT-APPLE-ONLY rows are static read-only / disabled
// markup and need no wiring. The Advanced tab has no folder-path control (that affordance is a
// File Transfer concern), so no folder-picker handler lives here.
public sealed partial class SettingsAdvancedView : UserControl
{
    public SettingsAdvancedView()
    {
        InitializeComponent();
    }
}
