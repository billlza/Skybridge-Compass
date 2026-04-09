use futures::channel::mpsc;
use image::GenericImageView;
use ksni::TrayMethods;
use std::sync::LazyLock;

const APP_ICON_NAME: &str = "com.skybridge.compass.ubuntu";

fn tray_icon_pixmap() -> ksni::Icon {
    static ICON: LazyLock<ksni::Icon> = LazyLock::new(|| {
        let image = image::load_from_memory_with_format(
            include_bytes!("../../skybridge-ui/assets/icons/skybridge-app-icon-64.png"),
            image::ImageFormat::Png,
        )
        .expect("bundled tray icon should be a valid PNG");
        let (width, height) = image.dimensions();
        let mut data = image.into_rgba8().into_vec();
        for pixel in data.chunks_exact_mut(4) {
            pixel.rotate_right(1);
        }
        ksni::Icon {
            width: width as i32,
            height: height as i32,
            data,
        }
    });

    ICON.clone()
}

#[derive(Debug, Clone)]
pub enum TrayUiEvent {
    ShowWindow,
    HideWindow,
    Quit,
}

#[derive(Debug)]
pub struct CompassTray {
    ui_tx: mpsc::UnboundedSender<TrayUiEvent>,
    status: ksni::Status,
}

impl CompassTray {
    pub fn new(ui_tx: mpsc::UnboundedSender<TrayUiEvent>, visible: bool) -> Self {
        Self {
            ui_tx,
            status: if visible {
                ksni::Status::Active
            } else {
                ksni::Status::Passive
            },
        }
    }

    pub fn set_visible(&mut self, visible: bool) {
        self.status = if visible {
            ksni::Status::Active
        } else {
            ksni::Status::Passive
        };
    }
}

impl ksni::Tray for CompassTray {
    fn id(&self) -> String {
        "skybridge-compass".into()
    }

    fn icon_name(&self) -> String {
        APP_ICON_NAME.into()
    }

    fn icon_pixmap(&self) -> Vec<ksni::Icon> {
        vec![tray_icon_pixmap()]
    }

    fn title(&self) -> String {
        "SkyBridge Compass".into()
    }

    fn status(&self) -> ksni::Status {
        self.status
    }

    fn activate(&mut self, _x: i32, _y: i32) {
        let _ = self.ui_tx.unbounded_send(TrayUiEvent::ShowWindow);
    }

    fn menu(&self) -> Vec<ksni::MenuItem<Self>> {
        use ksni::menu::*;

        vec![
            StandardItem {
                label: "Show Window".into(),
                icon_name: "window-restore".into(),
                activate: Box::new(|this: &mut Self| {
                    let _ = this.ui_tx.unbounded_send(TrayUiEvent::ShowWindow);
                }),
                ..Default::default()
            }
            .into(),
            StandardItem {
                label: "Hide Window".into(),
                icon_name: "window-minimize".into(),
                activate: Box::new(|this: &mut Self| {
                    let _ = this.ui_tx.unbounded_send(TrayUiEvent::HideWindow);
                }),
                ..Default::default()
            }
            .into(),
            MenuItem::Separator,
            StandardItem {
                label: "Quit".into(),
                icon_name: "application-exit".into(),
                activate: Box::new(|this: &mut Self| {
                    let _ = this.ui_tx.unbounded_send(TrayUiEvent::Quit);
                }),
                ..Default::default()
            }
            .into(),
        ]
    }
}

pub async fn spawn_tray(tray: CompassTray) -> Result<ksni::Handle<CompassTray>, ksni::Error> {
    tray.assume_sni_available(true).spawn().await
}
