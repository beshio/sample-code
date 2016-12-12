//
//  PopoverMenuController.swift
//
//  Created by beshio on 2015/11/03.
//  Copyright c 2015 beshio. All rights reserved.
//

// sequence to use this controller
// 1. create controlelr
//	let popupMenu = PopoverMenuController()
// 2. set souce view and rect and arrow direction
//	popupMenu.sourceView = someView
//	popupMenu.sourceRect = someRect
//	(optionally) popMenu.arrowDirection = UIPopoverArrowDirection.Up or whatever
// 2. add action items
//	let act1 = PopMenuAction(textLabel: "act1", accessoryType: UITableViewCellAccessoryType.None, handler: "someact1")
//  popupMenu.addAction(act1)
//	let act2 = PopMenuAction(textLabel: "act2", accessoryType: UITableViewCellAccessoryType.None, handler: "someact2")
//  popupMenu.addAction(act2)
//	...
// 3. optionally set timeout and delegate
//	popupMenu.timeoutValue = 4.0 or whatever
//	popupMenu.delegate = self or whatever. if delegate is set, done-status is given
// 4. present view controller
//	presentViewController(popupMenu, animated: true, completion: nil)

import UIKit

// pop menu item
//
class PopMenuAction: NSObject {
	var textLabel: String!
	var accessoryType: UITableViewCellAccessoryType!
	var handler: ((PopMenuAction?) -> Bool)!
	var tag: Int!	// 0 based sequence number of menu item
	init(textLabel: String, accessoryType: UITableViewCellAccessoryType, handler: ((PopMenuAction?) -> Bool)!) {
		super.init()
		self.textLabel = textLabel
		self.accessoryType = accessoryType
		self.handler = handler
	}
}

// to notify popover control result
//
protocol PopoverControllerProtocol {
	func popoverControllerDone(_ noaction: Bool, tot: Bool)
}

// popup menu using table view
//
class PopoverMenuController: UIViewController, UIPopoverPresentationControllerDelegate, UITableViewDataSource, UITableViewDelegate {
	var noActionTOT: Timer! = nil
	var timeoutValue: TimeInterval = 0.0
	var popMenuActions: [PopMenuAction] = []
	var tableView: UITableView!
	var cellFont: UIFont! = nil
	let cellId = "popMenuCell"
	var contentWidth: CGFloat = 0.0
	var contentHeight: CGFloat!
	var sourceView: UIView! = nil
	var sourceRect: CGRect! = nil
	var sourceBtnItem: UIBarButtonItem! = nil
	var arrowDirection = UIPopoverArrowDirection.any
	var delegate: PopoverControllerProtocol! = nil
	var exitWithTap = true		// true when exitting by tapping outside of popover menu
	var exitWhenSelected = true	// if set false, you need to exipilicitly call dismissPopOverMenu

	// get cell
	//
	func getCell(_ index: Int) -> UITableViewCell {
		let indexPath = IndexPath(row: index, section: 0)
		let cell = tableView.cellForRow(at: indexPath)
		return cell!
	}
	
	// dismiss popover menu
	func dismissPopOverMenu(_ animated: Bool) {
		super.dismiss(animated: animated, completion: nil)
	}
	
	// number of sections
	//
	func numberOfSections(in tableView: UITableView) -> Int {
		return 1
	}
	
	// number of rows
	//
	func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
		return popMenuActions.count
	}

	// cell selected
	//
	func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
		return indexPath
	}
	
	func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
		exitWithTap = false
		tableView.deselectRow(at: indexPath, animated: false)
		if (noActionTOT != nil) {
			noActionTOT.invalidate()
			noActionTOT = nil
		}
		let action = popMenuActions[(indexPath as NSIndexPath).row]
		var animated = true
		if (action.handler != nil) {
			animated = action.handler(action)
		}
		if (exitWhenSelected) {
			super.dismiss(animated: animated, completion: nil)
		}
		if (delegate != nil) {
			delegate.popoverControllerDone(false, tot: false)
		}
	}
	
	func tableView(_ tableView: UITableView, shouldHighlightRowAt indexPath: IndexPath) -> Bool {
		resetTot()
		return true
	}

	// gives cell data contents
	//
	func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
		var cell: UITableViewCell! = tableView.dequeueReusableCell(withIdentifier: cellId)
		if (cell == nil) {
			cell = UITableViewCell(style: UITableViewCellStyle.value1, reuseIdentifier: cellId)
		}
		let popMenuAction = popMenuActions[(indexPath as NSIndexPath).row]
		cell.textLabel?.text = popMenuAction.textLabel
		cell.textLabel?.font = cellFont
		cell.accessoryType = popMenuAction.accessoryType
		return cell
	}

	// add acttion
	//
	func addAction(_ action: PopMenuAction) {
		action.tag = popMenuActions.count
		popMenuActions.append(action)
		modalPresentationStyle = UIModalPresentationStyle.popover
		popoverPresentationController?.delegate = self
		popoverPresentationController?.permittedArrowDirections = arrowDirection
		if (cellFont == nil) {
			cellFont = UIFont.systemFont(ofSize: 17.0)
		}
		var width = action.textLabel.size(attributes: [NSFontAttributeName: cellFont]).width+36.0
		if (action.accessoryType != UITableViewCellAccessoryType.none) {
			width += 20.0
		}
		if (width > contentWidth) {
			contentWidth = width
		}
		contentHeight = 44.0*CGFloat(popMenuActions.count)-2.0
		preferredContentSize = CGSize(width: contentWidth, height: contentHeight)
		popoverPresentationController?.sourceView = sourceView
		if (sourceRect != nil) {
			popoverPresentationController?.sourceRect = sourceRect
		}
		popoverPresentationController?.barButtonItem = sourceBtnItem
	}

	// timeout
	//
	func handleTimeout(_ time: Timer) {
		exitWithTap = false
		noActionTOT = nil
		if (delegate != nil) {
			delegate.popoverControllerDone(true, tot: true)
		}
		super.dismiss(animated: true, completion: nil)
	}

	// reset TOT
	//
	func resetTot() {
		if (timeoutValue != 0.0 && noActionTOT != nil) {
			noActionTOT.invalidate()
			noActionTOT = nil
			startTot()
		}
	}
	
	// start timer
	//
	func startTot() {
		if (timeoutValue != 0.0) {
			noActionTOT = Timer.scheduledTimer(timeInterval: timeoutValue, target: self, selector: #selector(handleTimeout(_:)), userInfo: nil, repeats: false)
		}
	}
	
	// will disappear. call delegate if yet called
	//
	override func viewWillDisappear(_ animated: Bool) {
		super.viewWillDisappear(animated)
		if (exitWithTap) {
			if (noActionTOT != nil) {
				noActionTOT.invalidate()
				noActionTOT = nil
			}
			if (delegate != nil) {
				delegate.popoverControllerDone(true, tot: false)
			}
		}
	}
	
	// create popup menu
	//
	override func viewDidLoad() {
		super.viewDidLoad()
		let itemCount = popMenuActions.count
		if (itemCount == 0) {
			return
		}
		tableView = UITableView(frame: CGRect(x: 0.0, y: 0.0, width: contentWidth, height: contentHeight))
		tableView.dataSource = self
		tableView.delegate = self
		tableView.isScrollEnabled = false
		//tableView.layer.borderWidth = 1.0
		view.addSubview(tableView)
		view.frame = tableView.frame
		//view.backgroundColor = UIColor.whiteColor()
		startTot()
	}

	// delegate for popover
	//
	func adaptivePresentationStyle(for controller: UIPresentationController) -> UIModalPresentationStyle {
		return UIModalPresentationStyle.none
	}

	// need this for iPhone6 plus. http://stackoverflow.com/questions/29884416/setting-uimodalpresentationstyle-for-iphone-6-plus-in-landscape
	func adaptivePresentationStyle(for controller: UIPresentationController, traitCollection: UITraitCollection) -> UIModalPresentationStyle {
		return UIModalPresentationStyle.none
	}

#if DEBUG
	deinit {
		print("PopoverMenuController: deinit")
	}
#endif
}
