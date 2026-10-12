/// A cached UI surface still has to be bound to the native renderer for each run.
public enum RenderViewPreparation {
    public static func prepare<View: AnyObject>(cached: View?, create: () -> View, publish: (View) -> Void) -> View {
        let view = cached ?? create()
        publish(view)
        return view
    }
}
