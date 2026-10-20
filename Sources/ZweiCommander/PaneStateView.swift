import AppKit

final class PaneStateView: NSView {
    let heading = label("",size:16,weight:.medium)
    let detail = label("",size:12,color:.secondaryLabelColor)
    let action = ActionButton("",action:{})
    var background = NSColor.textBackgroundColor { didSet { needsDisplay = true } }
    override init(frame:NSRect) {
        super.init(frame:frame)
        heading.alignment = .center;detail.alignment = .center;detail.lineBreakMode = .byWordWrapping;detail.maximumNumberOfLines = 3
        [heading,detail,action].forEach { addSubview($0) };setAccessibilityRole(.group)
    }
    required init?(coder:NSCoder) { fatalError() }
    override var isOpaque: Bool { true }
    override func hitTest(_ point:NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === action || hit?.isDescendant(of:action) == true ? hit : nil
    }
    override func draw(_ dirtyRect:NSRect) { background.setFill();bounds.fill(using:.sourceOver) }
    func show(_ title:String,detail message:String,button:String? = nil,perform:(()->Void)? = nil) {
        heading.stringValue = title;detail.stringValue = message;detail.toolTip = message
        action.title = button ?? "";action.isHidden = button == nil;action.perform = perform
        action.toolTip = title+" · "+message
        setAccessibilityLabel(title+". "+message);isHidden = false;needsLayout = true
    }
    override func layout() {
        super.layout();let width = max(1,bounds.width-32),center = bounds.midY
        let hasAction = !action.title.isEmpty
        heading.isHidden = bounds.height < 24 || (hasAction && bounds.height < 76)
        detail.isHidden = bounds.height < 150;action.isHidden = !hasAction || bounds.height < 24
        if bounds.height < 150 {
            heading.frame = NSRect(x:16,y:hasAction ? bounds.height-29 : center-12,width:width,height:24)
            action.frame = NSRect(x:max(8,(bounds.width-160)/2),y:hasAction && bounds.height >= 76 ? max(3,center-29) : center-13,width:min(160,width),height:26)
            return
        }
        heading.frame = NSRect(x:16,y:center+24,width:width,height:26)
        detail.frame = NSRect(x:16,y:center-25,width:width,height:46)
        action.frame = NSRect(x:max(8,(bounds.width-160)/2),y:center-66,width:min(160,width),height:30)
    }
}
