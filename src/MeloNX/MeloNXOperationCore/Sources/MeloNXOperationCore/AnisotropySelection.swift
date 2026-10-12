/// The slider uses zero for automatic filtering; native options use -1.
public enum AnisotropySelection {
    public static func nativeValue(for slider: Float) -> Float {
        slider.isFinite && slider >= 1 && slider <= 16 ? slider : -1
    }
    public static func sliderValue(for native: Float) -> Float {
        nativeValue(for: native) == -1 ? 0 : native
    }
}
