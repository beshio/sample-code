//
//  MapViewController.swift
//  MinAtlas
//
//  Created by Beshio on 2015/06/27.
//  Copyright (c) 2015 beshio. All rights reserved.
//

import UIKit

// scrollview subclass to avoid delay in touch in mapview
// http://stackoverflow.com/questions/3642547/uibutton-touch-is-delayed-when-in-uiscrollview
class MapScrollview: UIScrollView, UIGestureRecognizerDelegate {
    override func touchesShouldCancelInContentView(view: UIView) -> Bool {
        if (view is UIButton) {
            return  true
        }
        return super.touchesShouldCancelInContentView(view)
    }

	// this for allowing another recognizer of time out clear detection
	//
//	var handleGesture = false
//	func gestureRecognizer(gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWithGestureRecognizer otherGestureRecognizer: UIGestureRecognizer) -> Bool {
//		return false
//	}
}

// map tile layer
//
class TileLayer: CALayer {
	var readyUsed: Bool = false // used for current display
	var tileNum: UInt32 = 0xffffffff    // tile number
   	var scaleIdx: Int = 0		// map scale index
#if DEBUG
	var tileGenNum = 0          // tile gen sequence number for debug
#endif
}

// view to show a map. holds TileLayer blocks in its layer
//
class TileContainerSubview: UIView {
	var centerXpos: Double = 0.0	// x map-coordinate that corresponds to displayed screen center
	var centerYpos: Double = 0.0	// y map-coordinate that corresponds to displayed screen center
	var xmaxTileNum: Int32 = 0		// max. tile x number, inclusive
	var ymaxTileNum: Int32 = 0		// max. tile y number, inclusive
   	var scaleIdx: Int = 0			// map scale index
}

// view to hold two TileContainerSubview, child view of UIScrollView. one view for current map, another for next map for fast zooming
//
class TileContainerView: UIView {
	var tileContainerSubviews: [TileContainerSubview!] = []
	weak var scrollView: UIScrollView!  // parent UIScrollView
	var currScaleIdx = 0
}

// request data block for tile data
//
struct TileReq {
	var tileList: [UInt32] = []
	var reuseTile: [TileLayer] = []
	var scaleIdx: Int
	var flush: Bool
}

// request block for invisible (=out of visible screen area) tile data prefetch
//
struct InvisibleTileReq {
	var contour: Bool           // true when contour tile for zoom-out prefetch
	var scaleIdx: Int			// map scale index
	var xdir: Int32				// x scroll direction
	var ydir: Int32				// y scroll direction
	var centerTileX: Int32		// tile number for screen center in x dir
	var centerTileY: Int32		// tile number for screen center in y dir
	var nleft: Int32			// tile range at last display. this for prefetch
	var nright: Int32			// tile range at last display. this for prefetch
	var ntop: Int32				// tile range at last display. this for prefetch
	var nbottom: Int32			// tile range at last display. this for prefetch
}

// request block for visible (=w/in visible screen area) tile data
//
struct VisibleTileReq {
	var scaleIdx: Int			// map scale index
	var zoomScale: Double		// zoom scale
	var centerXpos: Double		// x map-coordinate that corresponds to displayed screen center
	var centerYpos: Double		// y map-coordinate that corresponds to displayed screen center
	var initReady: Bool			// initialize readyUsed of readyTileRayer[], also it means request for currently displayed view
}

// back log to set contents and adding to super layer
//
struct TileLayerBackLog {
	var tileLayer: TileLayer!
	var imageRef: CGImageRef!
	var superLayer: CALayer!
	var scaleIdx: Int
}

// map ops mode
//
enum MapMode: Int {
	case None
	case MapDisplay		// regular map display
	case RouteEdit		// route edit mode
}

// handles map display
//
class MapViewController: UIViewController, UIScrollViewDelegate, UIGestureRecognizerDelegate, /*ActionControllerProtocol,*/ LocationSearchProtocol {
	// constants to define ops
	let mapChangeAnimation = true	// animate when changing map
	let abortMapChangeAnimation = false	// abort map change animation if previous map can't fill entire screen
	let drawAsync = false			// draw asynchronously. not quite sure what it means...
	let TILE_W: Int32 = 256			// width of tile
	let DTILE_W: Double = 256.0
	let TILE_H: Int32 = 256			// height of tile
	let DTILE_H: Double = 256.0

	var orientation = UIInterfaceOrientation.Unknown
	var mapobj: MapObject!			// map object
	var scaleDescs: [ScaleDesc] = []	// scale descriptors
	var currScaleIdx = 0			// currently displayed map index
	var scrollView: MapScrollview!			// scroll view to hold tile container
	var tileContainerView: TileContainerView!	// tile container view, subview of scrollView
	var tileContainerSubview: TileContainerSubview!	// current container subview
	var prevTileContainerSubview: TileContainerSubview! = nil	// previous container subview
	var readyTileLayer: [TileLayer!] = []	// already created ready tile buffer
	var centerLat = 0.0		// latitude of display center
	var centerLon = 0.0		// longitude of display center
#if DEBUG
	var tileGenNum : Int = 0	// generated serial tile number for test
#endif
	var minZoomScale: Double = 0.0
	var maxZoomScale: Double = 0.0
	var refCenterXpos = 0.0
	var refCenterYpos = 0.0
	
	var srque: dispatch_queue_t!	// serial dispatch queue for GCD
	var dspgrp: dispatch_group_t!	// dispatch group for background thread completion
	var dsem: dispatch_semaphore_t!	// semaphore to access readyTileLayer[], tileReq[]
	var wsem: dispatch_semaphore_t!	// semaphore to make sure tile gen programs to run sequencially w/ min. intervention
	var msem: dispatch_semaphore_t!	// semaphore to access mapobj and scaleIdx of view
	var bsem: dispatch_semaphore_t!	// semaphore to access backLogArray
	
	enum ZoomInProcess: Int {
		case NotReady		// system not ready
		case BusyNow		// already w/in zooming code. do nothing
		case Ready			// not on map chaning.
		case MapChangeOngoing	// map change is on going. do several special ops
	}
    var zoomInProcess = ZoomInProcess.NotReady	// 0: idle, 1: inhibit processing, 10: after user zoom/scroll
    var refZoomScale: Double = 0.0

    var toolBar: UIToolbar! = nil   // container of buttons
    var toolBarVisible = false
	var prevOrientation = UIInterfaceOrientation.Unknown
	var locSrchViewController: LocationSearchViewController! = nil  // location name search view ctrl

	var opsMode = MapMode.MapDisplay	// map operation mode

#if DEBUG
	deinit {
		print("MapViewController deinit")
	}
#endif

	// set constraints to toolbar to stay bottom. this helps a lot. http://stackoverflow.com/questions/12826878/creating-layout-constraints-programmatically
	//
	func setToolbarConstraints(tooBar: UIToolbar) {
		tooBar.translatesAutoresizingMaskIntoConstraints = false
		let width = NSLayoutConstraint(item: tooBar, attribute: NSLayoutAttribute.Width, relatedBy: NSLayoutRelation.Equal, toItem: view, attribute: NSLayoutAttribute.Width, multiplier: 1.0, constant: 0.0)
		let left = NSLayoutConstraint(item: tooBar, attribute: NSLayoutAttribute.Left, relatedBy: NSLayoutRelation.Equal, toItem: view, attribute: NSLayoutAttribute.Left, multiplier: 1.0, constant: 0.0)
		let height = NSLayoutConstraint(item: tooBar, attribute: NSLayoutAttribute.Height, relatedBy: NSLayoutRelation.Equal, toItem: nil, attribute: NSLayoutAttribute.NotAnAttribute, multiplier: 1.0, constant: 46.0)
		let bottom = NSLayoutConstraint(item: tooBar, attribute: NSLayoutAttribute.Bottom, relatedBy: NSLayoutRelation.Equal, toItem: view, attribute: NSLayoutAttribute.Bottom, multiplier: 1.0, constant: 0.0)
		view.addConstraints([width, left, height, bottom])
	}
	
	// route edit var. code body is in MapViewControllerEditRoute.swift
	var routeToolBar: UIToolbar!		// tool bar for route edit
	var rtobj: RouteEditObj! = nil
	var guideMsg: OutlineLabel! = nil
	var guideMsgTop: NSLayoutConstraint! = nil

	// set map mode
	//
	func setMapMode(newOpsMode: MapMode, any: AnyObject!) {
		if (newOpsMode == MapMode.RouteEdit) {
			// set editedRoute before calling this func, or this func would die
			if (opsMode == MapMode.MapDisplay) {
				if (locSrchViewController == nil) {
					let storyboard: UIStoryboard = UIStoryboard(name: "LocationSrch", bundle: NSBundle.mainBundle())
					locSrchViewController = storyboard.instantiateInitialViewController() as! LocationSearchViewController
					addChildViewController(locSrchViewController)
					locSrchViewController.view.layer.zPosition = 1000.0
					locSrchViewController.delegate = self
				}
				if (toolBarVisible) {
					toolBar.removeFromSuperview()
				} else {
					view.addSubview(locSrchViewController.view)
				}
				if (wayptObj != nil) {
					wayptObj.enabled = false
				}
				if (routeObj != nil) {
					routeObj.hidden = true
				}
				if (gpsTrackObj != nil) {
					gpsTrackObj.hidden = true
				}
				if (mapAnnotation == nil) {
					mapAnnotation = MapAnnotationObj(view: tileContainerView)
					mapAnnotation.mapObject = mapobj
				}
				scrollView.removeGestureRecognizer(longTap)
			}
			setupRouteEditMode(any as! RouteNameRestoreData)
			mapAnnotation.purgeTrack()
			mapAnnotation.drawTracksInTiles()
			mapAnnotation.annotateMap()
		} else if (newOpsMode == MapMode.MapDisplay) {
			if (opsMode == MapMode.RouteEdit) {
				if (toolBarVisible) {
					view.addSubview(toolBar)
					setToolbarConstraints(toolBar)
				}
				if (wayptObj != nil) {
					wayptObj.enabled = true
				}
				scrollView.addGestureRecognizer(longTap)
				var needUpdate = false
				if (routeObj != nil) {
					routeObj.hidden = false
					needUpdate = true
				}
				if (gpsTrackObj != nil) {
					gpsTrackObj.hidden = false
					needUpdate = true
				}
				if (needUpdate && mapAnnotation != nil) {
					mapAnnotation.purgeTrack()
					mapAnnotation.annotateMap()
				}
			}
		}
		opsMode = newOpsMode
	}
	
	// LocationSearchProtocol
	//
	// get reference point
	//
	func locationSearchRefPoint() -> (lat: Double, lon: Double) {
		var lat = 0.0, lon = 0.0
		mapobj.xy2latlonWithScaleIndex(currScaleIdx, x: tileContainerSubview.centerXpos, y: tileContainerSubview.centerYpos, lat: &lat, lon: &lon)
		if (opsMode == MapMode.MapDisplay) {
			return (lat: lat, lon: lon)
		}
		return routeEditRefLatLon(lat, lon: lon)
	}
	
	// search result
	//
	func locationSearchResult(name: String!, lat: Double, lon: Double) {
		if (name == nil) {
			// no valid location selected
			return
		}
		centerLat = lat
		centerLon = lon
		if (opsMode == MapMode.RouteEdit) {
			routeEditSearchResult(lat, lon: lon)
		}
		dispMapWithCenterLatLon()
	}
	
	func locationSearchCanceled() {
	}
	
	func locationSeachWillStart() {
	}

    // setCurrentScale()
	//
	func setCurrentScale(scaleIdx: Int) {
		currScaleIdx = scaleIdx
		dispatch_semaphore_wait(msem, DISPATCH_TIME_FOREVER)
		mapobj.currScale = scaleDescs[scaleIdx].scale
		tileContainerSubview = tileContainerSubviews[scaleIdx]
		tileContainerView.currScaleIdx = scaleIdx
		dispatch_semaphore_signal(msem)
	}
	
	// display map w/ center lat/lon
	//
	func dispMapWithCenterLatLon() {
#if VERBOSE1
		print("===== dispMapWithCenterLatLon =====")
		print("centerLat = \(centerLat) : centerLon = \(centerLon)")
#endif
		// get center tile number and offset in tile in pixel
		mapobj.latlon2xy(centerLat, lon: centerLon, x: &refCenterXpos, y: &refCenterYpos)
		tileContainerSubview.centerXpos = refCenterXpos
		tileContainerSubview.centerYpos = refCenterYpos
#if VERBOSE1
		print("centerXpos = \(tileContainerSubview.centerXpos) : centerYpos = \(tileContainerSubview.centerYpos)")
#endif
		let screenSiz = UIScreen.mainScreen().bounds.size
		let xorg = tileContainerSubview.centerXpos * Double(scrollView.zoomScale) - Double(screenSiz.width) * 0.5
		let yrange = DTILE_H * Double(tileContainerSubview.ymaxTileNum+1)
		let yorg = (yrange - tileContainerSubview.centerYpos) * Double(scrollView.zoomScale) - Double(screenSiz.height) * 0.5
		scrollView.contentOffset = CGPoint(x: CGFloat(xorg), y: CGFloat(yorg))
	}
	
	var nmaxTiles: Int32 = 0
	var tileReq: [TileReq] = []		// new tile data request block
	var invisibleTileReqQueue: [InvisibleTileReq] = []   // tile request queue
	var invisibleTileReq = InvisibleTileReq(contour: false, scaleIdx: 0, xdir: 0, ydir: 0, centerTileX: 0, centerTileY: 0, nleft: 0, nright: 0, ntop: 0, nbottom: 0)
	var visibleTileReqQueue: [VisibleTileReq] = []	// tile request queue
	var backLogArray: [[TileLayerBackLog]] = []
	
	// create tile data and set as sub layer data
	//
	func setTileLayerData() {
#if VERBOSE1
		print("***** setTileLayerData *****")
#endif
		dispatch_semaphore_wait(dsem, DISPATCH_TIME_FOREVER)
		var treq = tileReq[0]
		dispatch_semaphore_signal(dsem)
		let numNewTiles = treq.tileList.count
		// request tile data
		dispatch_semaphore_wait(msem, DISPATCH_TIME_FOREVER)
		let currScaleSave = mapobj.currScale
		mapobj.currScale = scaleDescs[treq.scaleIdx].scale
		mapobj.requestMapTiles(numNewTiles, tileList: treq.tileList)
		mapobj.currScale = currScaleSave
		dispatch_semaphore_signal(msem)
		let tileSubview = tileContainerSubviews[treq.scaleIdx]
#if VERBOSE1
		print("### numNewTiles = \(numNewTiles)")
#endif
		CATransaction.begin()
		CATransaction.setDisableActions(true)
		// CATransaction.setValue(0.0, forKey: kCATransactionAnimationDuration) <== this works, too
		// wait new tile data to be ready and create layer data
		let containerLayer = tileSubview.layer
		let ymaxTileNum = scaleDescs[treq.scaleIdx].ymaxTileNum
		var tileLayerBackLog: [TileLayerBackLog] = []
		for (var i = 0 ; i < numNewTiles ; i++) {
			// get tile data
			var tdat: UnsafeMutablePointer<UInt32> = nil
			var tidxtmp: Int32 = 0
			var tnumtmp: UInt32 = 0
			mapobj.getNextMapTile(&tdat, tileNum: &tnumtmp, tileIdx : &tidxtmp)
			// create CGImage and view
			let xtnum = Int32(tnumtmp&0xffff)
			let ytnum = Int32(tnumtmp>>16)
#if DEBUG
			let imageRef = createCGImageFromBitmap(String(tileGenNum), text2: "\(ytnum)-\(xtnum):\(treq.scaleIdx)", bitmap: UnsafeMutablePointer<UInt8>(tdat), width: Int(TILE_W), height: Int(TILE_H))
#else
			let imageRef = createCGImageFromBitmap(UnsafeMutablePointer<UInt8>(tdat), width: Int(TILE_W), height: Int(TILE_H))
#endif
			free(tdat)
			let layframe = CGRectMake(CGFloat(xtnum*TILE_W), CGFloat((ymaxTileNum-ytnum)*TILE_H), CGFloat(DTILE_W), CGFloat(DTILE_H))
			var tilelay: TileLayer!
			// create tile if still room for it
			dispatch_semaphore_wait(dsem, DISPATCH_TIME_FOREVER)
			if (treq.reuseTile.count == 0) {
				tilelay = TileLayer()
				tilelay.opaque = true
				tilelay.drawsAsynchronously = drawAsync
				tilelay.actions = noDefaultAnimation
#if DEBUG
				tilelay.borderWidth = 1
#endif
			} else {
				tilelay = treq.reuseTile.removeLast()  // last one
//				tilelay.removeFromSuperlayer()
			}
			tilelay.tileNum = tnumtmp
			tilelay.frame = layframe
			tilelay.scaleIdx = treq.scaleIdx
			tilelay.readyUsed = false
#if DEBUG
			tilelay.tileGenNum = tileGenNum++
#endif
			readyTileLayer.append(tilelay)
			var backLog = TileLayerBackLog(tileLayer: tilelay, imageRef: imageRef, superLayer: nil, scaleIdx: treq.scaleIdx)
			backLog.superLayer = containerLayer
			tileLayerBackLog.append(backLog)
			dispatch_semaphore_signal(dsem)
		}
		dispatch_semaphore_wait(bsem, DISPATCH_TIME_FOREVER)
		backLogArray.append(tileLayerBackLog)
		dispatch_semaphore_signal(bsem)
		dispatch_semaphore_wait(dsem, DISPATCH_TIME_FOREVER)
		tileReq[0].tileList.removeAll()
		tileReq[0].reuseTile.removeAll()
		tileReq.removeAtIndex(0)
		dispatch_semaphore_signal(dsem)
		if (treq.flush) {
			CATransaction.flush()
		}
		CATransaction.commit()
		treq.tileList.removeAll()
		treq.reuseTile.removeAll()
#if VERBOSE1
		print("***** setTileLayerData done: \(numNewTiles) *****")
#endif
	}

	// set backlog tile layer data
	//
	func setBackLogTileData() {
		var backUped: [Bool] = [Bool](count:scaleDescs.count, repeatedValue: false)
		let transform = UnsafeMutablePointer<CGAffineTransform>.alloc(scaleDescs.count)
		dispatch_semaphore_wait(bsem, DISPATCH_TIME_FOREVER)
		let bcount = backLogArray.count
		for (var i = 0 ; i < bcount ; i++) {
			var backLogs = backLogArray[i]
			let tcount = backLogs.count
			for (var j = 0 ; j < tcount ; j++) {
				let backLog = backLogs[j]
				let scaleIdx = backLog.scaleIdx
				let containerSubview = tileContainerSubviews[scaleIdx]
				if (!backUped[scaleIdx]) {
					backUped[scaleIdx] = true
					transform[scaleIdx] = containerSubview.transform
					containerSubview.transform = CGAffineTransformIdentity
				}
				backLog.tileLayer.contents = backLog.imageRef
				if (backLog.tileLayer.superlayer != nil) {
					if (containerSubview.layer != backLog.tileLayer.superlayer) {
						backLog.tileLayer.removeFromSuperlayer()
					}
				}
				containerSubview.layer.addSublayer(backLog.tileLayer)
			}
			backLogs.removeAll()
		}
		for (var i = 0 ; i < backUped.count ; i++) {
			if (backUped[i]) {
				tileContainerSubviews[i].transform = transform[i]
			}
		}
		backLogArray.removeAll()
		dispatch_semaphore_signal(bsem)
		transform.dealloc(scaleDescs.count)
	}

	// return varlue from createTileList() below
	enum NewTileListStatus : Int {
		case NothingToDo
		case CreateTiles
		case NoCreateButPrevOnGoing
	}
	
	// create new tile list that is not w/in tile cache (readyTileLayer[]) now
	//  tlist   : [in] tile list to be created if not in current ready list
	//	scidx	: [in] map scale index
	//
	// returns 0: if all of tiles are ready now, 1: if need to create new tiles, 2: no need to newly create but some are on creation now
	// note: call this func w/ dsem locked
	//
	func createNewTileList(tlist: [UInt32], scidx: Int, flushCA: Bool) -> NewTileListStatus {
		// check already created ready tiles and deterine new tiles to create
		let tlistCount = tlist.count
		var nready = readyTileLayer.count
		var readyUsed: [Bool] = [Bool](count: nready, repeatedValue: false)
		var newTileList: [UInt32] = []  // tile list to be newly created
		for (var i = 0 ; i < tlistCount ; i++) {
			var found = false
			for (var j = 0 ; j < nready ; j++) {
				if (readyTileLayer[j].tileNum == tlist[i] && readyTileLayer[j].scaleIdx == scidx) {
					readyUsed[j] = true
					found = true
					break
				}
			}
			if (!found) {
				// add to new tile list
				newTileList.append(tlist[i])
			}
		}
		// see if all tiles are ready now
		var numNewTiles = newTileList.count
		if (numNewTiles == 0) {
			return NewTileListStatus.NothingToDo
		}
		// see if already on creation process
		let ntreq = tileReq.count
		for (var i = 0 ; i < ntreq ; i++) {
			if (tileReq[i].scaleIdx != scidx) {
				// not the same map
				continue
			}
			let ntreq = tileReq[i].tileList.count
			for (var j = 0 ; j < numNewTiles ; j++) {
				for (var k = 0 ; k < ntreq ; k++) {
					if (tileReq[i].tileList[k] == newTileList[j]) {
						newTileList.removeAtIndex(j)
						numNewTiles--
						j--
						break
					}
				}
			}
		}
		if (numNewTiles == 0) {
			// no need to newly create tile but some are on creation process
			return NewTileListStatus.NoCreateButPrevOnGoing
		}
		// request new tiles
		var numDelete = nready + numNewTiles - Int(nmaxTiles)
		var reuseTile: [TileLayer] = [] // reused tile layer for visible display
		for (var i = 0 ; i < nready && numDelete > 0 ; i++) {
			if (!readyTileLayer[i].readyUsed && !readyUsed[i]) {
#if DEBUG && false
				print("delete: \(readyTileLayer[i].tileGenNum) : \(readyTileLayer[i].tileNum>>16)-\(readyTileLayer[i].tileNum&0xffff)")
#endif
				numDelete--
				reuseTile.append(readyTileLayer[i])
				readyTileLayer[i] = nil
				readyTileLayer.removeAtIndex(i)
				readyUsed.removeAtIndex(i)
				nready--
				i--
			}
		}
		let treq = TileReq(tileList: newTileList, reuseTile: reuseTile, scaleIdx: scidx, flush: flushCA)
		tileReq.append(treq)
		return NewTileListStatus.CreateTiles
	}
	
	// set tile layer data that is w/in screen area. this is for either current visible view or next scale data as prefetch
	//
	func setVisibleTileData() {
		let visibleTileReq = visibleTileReqQueue.removeAtIndex(0)
		let zoomScale = visibleTileReq.zoomScale
		let initReady = visibleTileReq.initReady
		let scidx = visibleTileReq.scaleIdx
		// get current screen size in point
		let dispTileSiz = DTILE_W * zoomScale
		// determine x tile range
		let centerXpos = visibleTileReq.centerXpos
		let xOffset = (centerXpos % DTILE_W) * zoomScale  // offset w/in tile from tile's left
		let screenSiz = UIScreen.mainScreen().bounds.size
		let sww = Double(screenSiz.width) * 1.01  // make it slightly larger to avoid possible rounding effect of floating point arithmatic
		let shh = Double(screenSiz.height) * 1.01
		let cx = sww * 0.5
		var x0 = cx - xOffset
		var nleft: Int32 = 0
		if (x0 > 0.0) {
			nleft = Int32(x0 / dispTileSiz)
			if (x0 % dispTileSiz != 0.0) {
				nleft++
			}
		}
		x0 += dispTileSiz
		var nright: Int32 = 0
		if (x0 < sww) {
			let xr = sww - x0
			nright = Int32(xr / dispTileSiz)
			if (xr % dispTileSiz != 0.0) {
				nright++
			}
		}
		let centerTileX = Int32(centerXpos / DTILE_W)
#if VERBOSE1
		print("x=\(centerXpos) : \(centerTileX-nleft)..\(centerTileX)..\(centerTileX+nright)")
#endif
		// determine y tile range
		let centerYpos = visibleTileReq.centerYpos
		let yOffset = (DTILE_H - (centerYpos % DTILE_H)) * zoomScale  // offset w/in tile from tile's top
		let cy = shh * 0.5
		var y0 = cy - yOffset  // distance from screen top
		var ntop: Int32 = 0
		if (y0 > 0.0) {
			ntop = Int32(y0 / dispTileSiz)
			if (y0 % dispTileSiz != 0.0) {
				ntop++
			}
		}
		y0 += dispTileSiz
		var nbottom: Int32 = 0
		if (y0 < shh) {
			let yb = shh - y0
			nbottom = Int32(yb / dispTileSiz)
			if (yb % dispTileSiz != 0.0) {
				nbottom++
			}
		}
		let centerTileY = Int32(centerYpos / DTILE_H)
#if VERBOSE1
		print("y=\(centerYpos) : \(centerTileY-nbottom)..\(centerTileY)..\(centerTileY+ntop)")
#endif
		// create tile list and set center of tile in screen
		let xmaxTileNum = scaleDescs[scidx].xmaxTileNum
		let ymaxTileNum = scaleDescs[scidx].ymaxTileNum
		var tlist: [UInt32] = []   // tile list to be displayed
		var ymin = centerTileY - nbottom
		if (ymin < 0) {
			ymin = 0
		}
		var ymax = centerTileY + ntop
		if (ymax > ymaxTileNum) {
			ymax = ymaxTileNum
		}
		var xmin = centerTileX - nleft
		if (xmin < 0) {
			xmin = 0
		}
		var xmax = centerTileX + nright
		if (xmax > xmaxTileNum) {
			xmax = xmaxTileNum
		}
		for (var i = ymax ; i >= ymin ; i--) {
			for (var j = xmin ; j <= xmax ; j++) {
				tlist.append((UInt32(i)<<16)|UInt32(j))
			}
		}
		let ttlDispTiles = tlist.count
#if VERBOSE1
		print("*** visible tile count = \(ttlDispTiles) ***")
#endif
#if DEBUG && false
		for (var i = 0 ; i < ttlDispTiles ; i++) {
			print("tlist[\(i)] = \(tlist[i]>>16)-\(tlist[i]&0xffff)")
		}
#endif
		dispatch_semaphore_wait(dsem, DISPATCH_TIME_FOREVER)
		dispatch_semaphore_signal(wsem)
		if (initReady) {
			// sync mode now. set tile number for animation support while map change
			dispYminTile = Int(ymin)
			dispYmaxTile = Int(ymax)
			dispXminTile = Int(xmin)
			dispXmaxTile = Int(xmax)
			// init ready-used flags of tile layer data
			let nready = readyTileLayer.count
			if (!onTransitionAnimation) {
				for (var i = 0 ; i < nready ; i++) {
					readyTileLayer[i].readyUsed = false
				}
			} else {
				for (var i = 0 ; i < nready ; i++) {
					let tlay = readyTileLayer[i]
					if (tlay.scaleIdx == onTransitionScaleIdx) {
						let x = Int(tlay.tileNum & 0xffff)
						if (x >= onTransitionXminTile && x <= onTransitionXmaxTile) {
							let y = Int(tlay.tileNum>>16)
							if (y >= onTransitionYminTile && y <= onTransitionYmaxTile) {
								// don't touch tiles used for on-going animation
								continue
							}
						}
					}
					tlay.readyUsed = false
				}
			}
		}
		// create new tile list
		let stat = createNewTileList(tlist, scidx: scidx, flushCA: !initReady)
#if VERBOSE1
		print("stat = \(stat)")
#endif
		dispatch_semaphore_signal(dsem)
		if (stat == NewTileListStatus.NothingToDo) {
			// all of tiles are ready now
			if (!initReady) {
				// we are on asynchronous mode. nothing to do further
				return
			}
		} else if (stat == NewTileListStatus.NoCreateButPrevOnGoing) {
			// no need to newly create but creation still on going
			if (!initReady) {
				// we are on asynchronous mode. nothing to do further
				return
			}
			dispatch_group_wait(dspgrp, DISPATCH_TIME_FOREVER)
		} else {
			// create tile and set in sublayer
			if (!initReady) {
				// we are already on asynchronous mode. execute directly
				setTileLayerData()
				return
			}
			dispatch_sync(srque, setTileLayerData)
		}
		// set ready-used flags to tile layer data
		dispatch_semaphore_wait(dsem, DISPATCH_TIME_FOREVER)
		let nready = readyTileLayer.count
		for (var j = 0 ; j < ttlDispTiles ; j++) {
			for (var i = nready-1 ; i >= 0 ; i--) {  // newer tiles are at last part, so this buys some time reduction
				if (readyTileLayer[i].tileNum == tlist[j] && readyTileLayer[i].scaleIdx == currScaleIdx) {
					readyTileLayer[i].readyUsed = true
					break
				}
			}
		}
		dispatch_semaphore_signal(dsem)
		// prep for succeeding prefetch
		let newCenterXpos = tileContainerSubview.centerXpos
		let newCenterYpos = tileContainerSubview.centerYpos
		let xdir = newCenterXpos - refCenterXpos
		let ydir = newCenterYpos - refCenterYpos
		refCenterXpos = newCenterXpos
		refCenterYpos = newCenterYpos
		invisibleTileReq.contour = false
		invisibleTileReq.scaleIdx = currScaleIdx
		invisibleTileReq.xdir = Int32(xdir)
		invisibleTileReq.ydir = Int32(ydir)
		invisibleTileReq.centerTileX = centerTileX
		invisibleTileReq.centerTileY = centerTileY
		invisibleTileReq.nleft = nleft
		invisibleTileReq.nright = nright
		invisibleTileReq.ntop = ntop
		invisibleTileReq.nbottom = nbottom
	}
	
	// set tile layer data that is out side of screen area (contour) as prefetch
	//
	func setInvisibleTileData() {
		let invisibleTileReq = invisibleTileReqQueue.removeAtIndex(0)
		// request map data prefetch for fast scroll
		let xdir = invisibleTileReq.xdir
		let ydir = invisibleTileReq.ydir
		let contour = invisibleTileReq.contour
		if (!contour && (xdir <= 1 && xdir >= -1 && ydir <= 1 && ydir >= -1)) {
			// ignore very small diff
			dispatch_semaphore_signal(wsem)
			return
		}
		let centerTileX = invisibleTileReq.centerTileX
		var xvr: Int32 = -1
		var xvl: Int32 = -1
		let nright = invisibleTileReq.nright
		let nleft = invisibleTileReq.nleft
		if (contour) {
			xvr = centerTileX + nright + 1
			xvl = centerTileX - nleft - 1
		} else if (xdir > 0) {
			xvr = centerTileX + nright + 1
		} else if (xdir < 0) {
			xvl = centerTileX - nleft - 1
		}
		let centerTileY = invisibleTileReq.centerTileY
		let ntop = invisibleTileReq.ntop
		let nbottom = invisibleTileReq.nbottom
		var yvs: Int32 = centerTileY + ntop
		var yve: Int32 = centerTileY - nbottom
		var yht: Int32 = -1
		var yhb: Int32 = -1
		if (contour) {
			yvs++
			yve--
			yht = centerTileY + ntop + 1
			yhb = centerTileY - nbottom - 1
		} else if (ydir > 0) {
			yvs++
			yht = centerTileY + ntop + 1
		} else if (ydir < 0) {
			yve--
			yhb = centerTileY - nbottom - 1
		}
		let xhs: Int32 = centerTileX - nleft
		let xhe: Int32 = centerTileX + nright
		var tlist: [UInt32] = []
		// vertical tiles
		let scaleIdx = invisibleTileReq.scaleIdx
		let xmaxTileNum = scaleDescs[scaleIdx].xmaxTileNum
		let ymaxTileNum = scaleDescs[scaleIdx].ymaxTileNum
		if (xvl >= 0 && xvl <= xmaxTileNum) {
			for (var i = yvs ; i >= yve ; i--) {
				if (i < 0 || i > ymaxTileNum) {
					continue;
				}
				tlist.append((UInt32(i)<<16)|UInt32(xvl))
			}
		}
		if (xvr >= 0 && xvr <= xmaxTileNum) {
			for (var i = yvs ; i >= yve ; i--) {
				if (i < 0 || i > ymaxTileNum) {
					continue
				}
				tlist.append((UInt32(i)<<16)|UInt32(xvr))
			}
		}
		// horizontal tiles
		if (yht >= 0 && yht <= ymaxTileNum) {
			for (var i = xhs ; i <= xhe ; i++) {
				if (i < 0 || i > xmaxTileNum) {
					continue
				}
				tlist.append((UInt32(yht)<<16)|UInt32(i))
			}
		}
		if (yhb >= 0 && yhb <= ymaxTileNum) {
			for (var i = xhs ; i <= xhe ; i++) {
				if (i < 0 || i > xmaxTileNum) {
					continue
				}
				tlist.append((UInt32(yhb)<<16)|UInt32(i))
			}
		}
		if (tlist.count == 0) {
			dispatch_semaphore_signal(wsem)
			return
		}
		// create new tile list
		dispatch_semaphore_wait(dsem, DISPATCH_TIME_FOREVER)
		dispatch_semaphore_signal(wsem)
		let stat = createNewTileList(tlist, scidx: currScaleIdx, flushCA: true)
		dispatch_semaphore_signal(dsem)
		if (stat != NewTileListStatus.CreateTiles) {
			// tiles already ready or creation on goining
			return
		}
#if VERBOSE1 && true
		dispatch_semaphore_wait(dsem, DISPATCH_TIME_FOREVER)
		let reqidx = tileReq.count-1
		let nreq = tileReq[reqidx].tileList.count
		print("prefetch: \(tlist.count): actual = \(nreq)")
		for (var i = 0 ; i < nreq ; i++) {
			print("\(tileReq[reqidx].scaleIdx):\(tileReq[reqidx].tileList[i]>>16)-\(tileReq[reqidx].tileList[i]&0xffff)")
		}
		dispatch_semaphore_signal(dsem)
#endif
		// create tile data
		setTileLayerData()
	}
	
	// prefetch tile data for the next detailed/larger scale
	//
	func setZoomInOutTileData(zinout: Int, zscale: Double) {
#if VERBOSE1
		print("$$$$$ zoom-in/out [\(currScaleIdx) + \(zinout)] : \(zscale) : prefetch for next scale $$$$$")
#endif
		// calc center lat,lon from x,y
		// we need to set mapobj.currScale to make sure map object is built. don't use xy2latlonWithScaleIndex() here
		dispatch_semaphore_wait(msem, DISPATCH_TIME_FOREVER)
		mapobj.xy2latlon(tileContainerSubview.centerXpos, y: tileContainerSubview.centerYpos, lat: &centerLat, lon: &centerLon)
		// calc x,y in new scale
		let scaleSave = mapobj.currScale
		let zoomInOutScaleIdx = currScaleIdx + zinout
		mapobj.currScale = scaleDescs[zoomInOutScaleIdx].scale
		var cxpos = 0.0
		var cypos = 0.0
		mapobj.latlon2xy(centerLat, lon: centerLon, x: &cxpos, y: &cypos)
		mapobj.currScale = scaleSave
		dispatch_semaphore_signal(msem)
		let visibleTileReq = VisibleTileReq(scaleIdx: zoomInOutScaleIdx, zoomScale: zscale, centerXpos: cxpos, centerYpos: cypos, initReady: false)
		dispatch_semaphore_wait(wsem, DISPATCH_TIME_FOREVER)
		visibleTileReqQueue.append(visibleTileReq)
		dispatch_async(srque, setVisibleTileData)
#if VERBOSE1
		print("$$$$$ exit zoom-in/out prefetch $$$$$")
#endif
	}

	// prefetch contour tile data at zoom-out
	//
	func setContourTileData() {
#if VERBOSE1
		print("%%%%% zoom-out prefetch %%%%%")
#endif
		dispatch_semaphore_wait(wsem, DISPATCH_TIME_FOREVER)
		invisibleTileReq.contour = true
		invisibleTileReqQueue.append(invisibleTileReq)
		dispatch_group_async(dspgrp, srque, setInvisibleTileData)
#if VERBOSE1
		print("%%%%% exit zoom-out prefetch %%%%%")
#endif
	}

	// scroll control
	//
	func scrollViewDidScroll(scrollView: UIScrollView) {
		if (zoomInProcess == ZoomInProcess.NotReady) {
			// system not yet ready
			return
		}
#if VERBOSE1
		print("\n***** scrollViewDidScroll: zoomInProcess = \(zoomInProcess) *****")
		print("scaleIndex = \(currScaleIdx)")
#endif
		if (zoomInProcess == ZoomInProcess.BusyNow) {
#if VERBOSE1
			print("***** exit scrollViewDidScroll-0 *****")
#endif
			return
		}
		let screenSiz = UIScreen.mainScreen().bounds.size
		let sw = Double(screenSiz.width)
		let sw05 = sw * 0.5
		let sh = Double(screenSiz.height)
		let sh05 = sh * 0.5
		let Zs = Double(scrollView.zoomScale)
		var aZs = Zs
		let rZs = 1.0/Zs
		if (zoomInProcess == ZoomInProcess.Ready) {
			// not in map swap state
			tileContainerSubview.centerXpos = (Double(scrollView.contentOffset.x) + sw05) * rZs
			let yrange = DTILE_H * Double(tileContainerSubview.ymaxTileNum+1)
			tileContainerSubview.centerYpos = yrange - (Double(scrollView.contentOffset.y) + sh05) * rZs
			if (mapAnnotation != nil) {
				mapAnnotation.centerXpos = tileContainerSubview.centerXpos
				mapAnnotation.centerYpos = tileContainerSubview.centerYpos
			}
		} else { // should be zoomInProcess == ZoomInProcess.MapChangeOngoing
			// in map swap state after zoom. calculate center so that zoom center position is the same for both scale maps
			let rScaleRatio = scaleDescs[zoomStartScaleIndex].scale / scaleDescs[currScaleIdx].scale
			aZs /= rScaleRatio
			let raZs = 1.0 / aZs
			let centerOfZoom = scrollView.pinchGestureRecognizer!.locationInView(view)
			let centerOfZoomOfView = scrollView.pinchGestureRecognizer!.locationInView(tileContainerSubviews[zoomStartScaleIndex])
#if VERBOSE1
			print("centerOfZoomOfView = \(centerOfZoomOfView)")
			print("scale ratio = \(1.0/rScaleRatio)")
#endif
			let xoff0 = Double(centerOfZoomOfView.x) - Double(scrollView.contentOffset.x) * rZs
			let xoff = xoff0 * rScaleRatio
			let x0 = zoomCurrXc - xoff
			tileContainerSubview.centerXpos = x0 + sw05 * raZs
			let yoff0 = Double(centerOfZoomOfView.y) - Double(scrollView.contentOffset.y) * rZs
			let yoff = yoff0 * rScaleRatio
			let y0 = zoomCurrYc + yoff
			tileContainerSubview.centerYpos = y0 - sh05 * raZs
			if (mapAnnotation != nil) {
				// annotation coordinates are calculated using the zoom start map
				mapAnnotation.centerXpos = (Double(scrollView.contentOffset.x) + sw05) * rZs
				let yrange = DTILE_H * Double(tileContainerSubviews[zoomStartScaleIndex].ymaxTileNum+1)
				mapAnnotation.centerYpos = yrange - (Double(scrollView.contentOffset.y) + sh05) * rZs
#if VERBOSE1
				print("annotaion center = \(mapAnnotation.centerXpos) : \(mapAnnotation.centerYpos)")
				print("center of zoom = \(centerOfZoom)")
#endif
			}
			if (abortMapChangeAnimation && onTransitionAnimation) {
				// map change animation is on going. check if previous map tiles are visible. if not, stop animation
				var zoomPrevXc = 0.0, zoomPrevYc = 0.0
				mapobj.latlon2xyWithScaleIndex(onTransitionScaleIdx, lat: zoomCenterLat, lon: zoomCenterLon, x: &zoomPrevXc, y: &zoomPrevYc)
				let prevAZs = Zs * scaleDescs[onTransitionScaleIdx].scale / scaleDescs[zoomStartScaleIndex].scale
				let prevRaZs = 1.0 / prevAZs
				let dispTileSiz = DTILE_W * prevAZs
				var stopAnimation = false
				// check w/ x
				let prevCenterXpos = zoomPrevXc - (Double(centerOfZoom.x) - sw * 0.5) * prevRaZs
				let xOffset = (prevCenterXpos % DTILE_W) * prevAZs  // offset w/in tile from tile's left
				let sww = sw * 1.05  // make it slightly larger to avoid possible rounding effect
				var x0 = sww * 0.5 - xOffset
				var nleft = 0
				if (x0 > 0.0) {
					nleft = Int(x0 / dispTileSiz)
					if (x0 % dispTileSiz != 0.0) {
						nleft++
					}
				}
				x0 += dispTileSiz
				var nright = 0
				if (x0 < sww) {
					let xr = sww - x0
					nright = Int(xr / dispTileSiz)
					if (xr % dispTileSiz != 0.0) {
						nright++
					}
				}
				let centerTileX = Int(prevCenterXpos / DTILE_W)
				var xmin = centerTileX - nleft
				if (xmin < 0) {
					xmin = 0
				}
#if VERBOSE1
				print("animation xmin : \(onTransitionXminTile) - \(xmin)")
#endif
				if (xmin < onTransitionXminTile) {
					// xmin out of range. stop animation
					stopAnimation = true
				} else {
					var xmax = centerTileX + nright
					if (xmax > Int(scaleDescs[onTransitionScaleIdx].xmaxTileNum)) {
						xmax = Int(scaleDescs[onTransitionScaleIdx].xmaxTileNum)
					}
#if VERBOSE1
					print("animation xmax : \(onTransitionXmaxTile) - \(xmax)")
#endif
					if (xmax > onTransitionXmaxTile) {
						stopAnimation = true
					}
				}
				// check w/ y
				if (!stopAnimation) {
					let prevCenterYpos = zoomPrevYc - (sh * 0.5 - Double(centerOfZoom.y)) * prevRaZs
					let yOffset = (DTILE_H - (prevCenterYpos % DTILE_H)) * prevAZs  // offset w/in tile from tile's top
					let shh = sh * 1.05  // make it slightly larger to avoid possible rounding effect
					var y0 = shh * 0.5 - yOffset  // distance from screen top
					var ntop = 0
					if (y0 > 0.0) {
						ntop = Int(y0 / dispTileSiz)
						if (y0 % dispTileSiz != 0.0) {
							ntop++
						}
					}
					y0 += dispTileSiz
					var nbottom = 0
					if (y0 < shh) {
						let yb = shh - y0
						nbottom = Int(yb / dispTileSiz)
						if (yb % dispTileSiz != 0.0) {
							nbottom++
						}
					}
					let centerTileY = Int(prevCenterYpos / DTILE_H)
					var ymin = centerTileY - nbottom
					if (ymin < 0) {
						ymin = 0
					}
#if VERBOSE1
					print("animation ymin : \(onTransitionYminTile) - \(ymin)")
#endif
					if (ymin < onTransitionYminTile) {
						// ymin out of range. stop animation
						stopAnimation = true
					} else {
						var ymax = centerTileY + ntop
						if (ymax > Int(scaleDescs[onTransitionScaleIdx].ymaxTileNum)) {
							ymax = Int(scaleDescs[onTransitionScaleIdx].ymaxTileNum)
						}
#if VERBOSE1
						print("animation ymax : \(onTransitionYmaxTile) - \(ymax)")
#endif
						if (ymax > onTransitionYmaxTile) {
							// ymax out of range. stop animation
							stopAnimation = true
						}
					}
				}
				if (stopAnimation) {
					CATransaction.begin()
					tileContainerSubview.layer.removeAllAnimations()
					prevTileContainerSubview.layer.removeAllAnimations()
					CATransaction.commit()
					onTransitionAnimation = false
					tileContainerSubview.alpha = 1.0
					//prevTileContainerSubview.alpha = 0.0
				}
			}
		}
#if VERBOSE1
		print("contentOffset : contentSize = \(scrollView.contentOffset) : \(scrollView.contentSize)")
		print("zoomScale = \(scrollView.zoomScale)")
		print("centerXpos = \(tileContainerSubview.centerXpos): centerYpos = \(tileContainerSubview.centerYpos)")
		print("tileContainerView.frame = \(tileContainerView.frame)")
		print("tileContainerView.center = \(tileContainerView.center)")
		print("tileContainerView.bounds = \(tileContainerView.bounds)")
		print("tileContainerView: a = \(tileContainerView.transform.a) : b = \(tileContainerView.transform.b) : c = \(tileContainerView.transform.c) : d = \(tileContainerView.transform.d) : tx = \(tileContainerView.transform.tx) : ty = \(tileContainerView.transform.ty)")
		print("tileContainerSubview: frame = \(tileContainerSubview.frame)")
		print("tileContainerSubview.center = \(tileContainerSubview.center)")
		print("tileContainerSubview.bounds = \(tileContainerSubview.bounds)")
		print("tileContainerSubview: a = \(tileContainerSubview.transform.a) : b = \(tileContainerSubview.transform.b) : c = \(tileContainerSubview.transform.c) : d = \(tileContainerSubview.transform.d) : tx = \(tileContainerSubview.transform.tx) : ty = \(tileContainerSubview.transform.ty)")
#endif
		// now get new tile data
		let visibleTileReq = VisibleTileReq(scaleIdx: currScaleIdx, zoomScale: aZs, centerXpos: tileContainerSubview.centerXpos, centerYpos: tileContainerSubview.centerYpos, initReady: true)
		dispatch_semaphore_wait(wsem, DISPATCH_TIME_FOREVER)
		visibleTileReqQueue.append(visibleTileReq)
		setVisibleTileData()
		setBackLogTileData()

		if (zoomInProcess == ZoomInProcess.MapChangeOngoing) {
			// no need to prefetch for zooming since it'll be taken care at didZoom
#if VERBOSE1
			print("***** exit scrollViewDidScroll, no prefetch *****")
#endif
            drawTrackLog()
			return
		}
		// prefetch tile data
		dispatch_semaphore_wait(wsem, DISPATCH_TIME_FOREVER)
		invisibleTileReqQueue.append(invisibleTileReq)
		dispatch_group_async(dspgrp, srque, setInvisibleTileData)
#if VERBOSE1
		print("***** exit scrollViewDidScroll-9 *****")
#endif
		drawTrackLog()
	}
	
	// scroll will begin. remember start point
	//
	func scrollViewWillBeginDragging(scrollView: UIScrollView) {
#if VERBOSE1
		print("begin dragging: \(scrollView.contentOffset)")
#endif
		refCenterXpos = tileContainerSubview.centerXpos
		refCenterYpos = tileContainerSubview.centerYpos
	}
	
	// returns view for zooming for iOS
	//
	func viewForZoomingInScrollView(scrollView: UIScrollView) -> UIView? {
		return tileContainerView
	}
#if false
	func scrollViewWillEndDragging(scrollView: UIScrollView!, withVelocity velocity: CGPoint, targetContentOffset: UnsafeMutablePointer<CGPoint>) {
		print("will end dragging: \(scrollView.contentOffset)")
	}
	
	func scrollViewDidEndDragging(scrollView: UIScrollView!, willDecelerate decelerate: Bool) {
		print("end dragging: \(scrollView.contentOffset) : \(decelerate)")
	}
	
	func scrollViewWillBeginDecelerating(scrollView: UIScrollView!) {
		print("begin decelerating: \(scrollView.contentOffset)")
	}
	
	func scrollViewDidEndDecelerating(scrollView: UIScrollView!) {
		print("end decelerating: \(scrollView.contentOffset)")
	}
#endif
	
	var zoomStartScaleIndex = 0
	var zoomCenterLat = 0.0			// zoom start center latitude (Note != view center). zoom center doen't change till zoom ends
	var zoomCenterLon = 0.0			// zoom start center longitude
	var zoomCurrXc = 0.0			// zoom current center x position. "Curr" means currently displayed map. varies after map change
	var zoomCurrYc = 0.0			// zoom current center y position
	var zoomStartXc = 0.0			// zoom start center x position. "start" means map where zoom started. doesn't change after map change
	var zoomStartYc = 0.0			// zoom styart center y position
	var onTransitionAnimation = false	// map is transiting and animation on going
	var onTransitionXminTile = 0	// xmin tile number of previous map
	var onTransitionXmaxTile = 0	// xmax tile number of previous map
	var onTransitionYminTile = 0	// ymin tile number of previous map
	var onTransitionYmaxTile = 0	// ymax tile number of previous map
	var onTransitionScaleIdx = 0	// map scale index of previous map
	var dispYminTile = 0			// ymin tile number for current view
	var dispYmaxTile = 0			// ymax tile number for current view
	var dispXminTile = 0			// xmin tile number for current view
	var dispXmaxTile = 0			// xmax tile number for current view

	// zoom will begin. remember initial center point and bounds size
	//
	func scrollViewWillBeginZooming(scrollView: UIScrollView, withView view: UIView?) {
#if VERBOSE1
		print("begin zooming: zoom: \(scrollView.zoomScale): offset \(scrollView.contentOffset)")
#endif
		zoomInProcess = ZoomInProcess.Ready
		refZoomScale = Double(scrollView.zoomScale)
        if (mapAnnotation != nil) {
            mapAnnotation.startZooming()
        }
		zoomStartScaleIndex = currScaleIdx
		let centerOfZoom = scrollView.pinchGestureRecognizer!.locationInView(self.view)
		zoomStartXc = Double((scrollView.contentOffset.x + centerOfZoom.x)/scrollView.zoomScale)
		let yRange0 = Double((tileContainerSubview.ymaxTileNum+1)*TILE_H)
		zoomStartYc = yRange0 - Double((scrollView.contentOffset.y + centerOfZoom.y)/scrollView.zoomScale)
		mapobj.xy2latlonWithScaleIndex(currScaleIdx, x: zoomStartXc, y: zoomStartYc, lat: &zoomCenterLat, lon: &zoomCenterLon)
#if VERBOSE1
		print("zoomCenterLat = \(zoomCenterLat)")
		print("zoomCenterLon = \(zoomCenterLon)")
#endif
	}

	// zoom control
	//
	func scrollViewDidZoom(scrollView: UIScrollView) {
		if (zoomInProcess == ZoomInProcess.NotReady) {
			return
		}
#if VERBOSE1
		print("\n##### scrollViewDidZoom: zoomInProcess = \(zoomInProcess) #####")
#endif
		if (zoomInProcess != ZoomInProcess.Ready && zoomInProcess != ZoomInProcess.MapChangeOngoing) {
#if VERBOSE1
			print("##### exit scrollViewDidZoom 0 #####")
#endif
			return
		}
#if VERBOSE1
		print("　zoom: \(scrollView.zoomScale): offset \(scrollView.contentOffset)")
#endif
		let zoomScale = Double(scrollView.zoomScale)
		var zInOut = 0
		if (zoomScale > refZoomScale) {
			// zoom-in
			if (currScaleIdx == 0) {
				// no further zoom-in
#if VERBOSE1
				print("##### exit scrollViewDidZoom 1 #####")
#endif
				refZoomScale = zoomScale
				return
			}
			let scaleRatio = scaleDescs[zoomStartScaleIndex].scale / scaleDescs[currScaleIdx-1].scale
		   	let mapChangeThreshold = minZoomScale * scaleRatio
			if (zoomScale < mapChangeThreshold) {
#if true
				if (zoomScale >= mapChangeThreshold * 0.8 && currScaleIdx != 0) {
					// prefetch next scale map data
					setZoomInOutTileData(-1, zscale: minZoomScale)
				}
#endif
#if VERBOSE1
				print("##### exit scrollViewDidZoom 2 #####")
#endif
				refZoomScale = zoomScale
				return
			}
#if VERBOSE1
			print("!!!!! zoom-in hit threashold: \(tileContainerView.bounds)")
			print("next scale = \(currScaleIdx-1)")
#endif
			zInOut = -1 // zoom-in
		} else if (zoomScale <= refZoomScale) {
			// zoom-out
			refZoomScale = zoomScale
			if (currScaleIdx == scaleDescs.count-1) {
				// no further zoom-out. prefetch outer contour tiles
				setContourTileData()
#if VERBOSE1
				print("##### exit scrollViewDidZoom 3 #####")
#endif
				return
			}
			let scaleRatio = scaleDescs[zoomStartScaleIndex].scale / scaleDescs[currScaleIdx].scale
			let mapChangeThreshold = minZoomScale * scaleRatio
#if VERBOSE1
			print("mapChangeThreshold = \(mapChangeThreshold)")
#endif
			if (zoomScale > mapChangeThreshold) {
				// prefetch outer contour tiles
				setContourTileData()
				if (zoomScale <= mapChangeThreshold * 1.25) {
#if true
					// prefetch next larger scale map data
					let nextZoomScale = minZoomScale * scaleDescs[currScaleIdx+1].scale / scaleDescs[currScaleIdx].scale
					setZoomInOutTileData(1, zscale: nextZoomScale)
#endif
				}
#if VERBOSE1
				print("##### exit scrollViewDidZoom 4 #####")
#endif
				return
			}
#if VERBOSE1
			print("!!!!! zoom-out hit threashold: \(tileContainerView.bounds)")
			print("next scale = \(currScaleIdx+1)")
#endif
			zInOut = 1  // zoom-out
		}
		// if still prev map change animation on going, stop it
		if (onTransitionAnimation) {
			// animation runs on another thread https://developer.apple.com/library/ios/documentation/WindowsViews/Conceptual/ViewPG_iPhoneOS/AnimatingViews/AnimatingViews.html
			// thus, onTransisionAnimation could change on the way. but it seems calling removeAllAnimations() has no effect while no animation
			// so attempt to finish animation anyway w/o checking if animation is really on going
			CATransaction.begin()
			tileContainerSubview.layer.removeAllAnimations()
			CATransaction.commit()
		}
		// set tile number range and scale index to preserve previous view's tile while animation
		onTransitionAnimation = true
		onTransitionScaleIdx = currScaleIdx
		onTransitionXminTile = dispXminTile
		onTransitionXmaxTile = dispXmaxTile
		onTransitionYminTile = dispYminTile
		onTransitionYmaxTile = dispYmaxTile
		// set curr/prev views
		prevTileContainerSubview = tileContainerSubview
		setCurrentScale(currScaleIdx+zInOut)
		// calc zoom center position w/ current and new map
		let centerOfZoom = scrollView.pinchGestureRecognizer!.locationInView(view)
		let zoomStartXc = Double((scrollView.contentOffset.x + centerOfZoom.x)/scrollView.zoomScale)  // zoom center x position at start scale
		let yRange0 = Double((tileContainerSubviews[zoomStartScaleIndex].ymaxTileNum+1)*TILE_H)  // zoom center y position at start scale
		let zoomStartYc = yRange0 - Double((scrollView.contentOffset.y + centerOfZoom.y)/scrollView.zoomScale)
		mapobj.latlon2xyWithScaleIndex(currScaleIdx, lat: zoomCenterLat, lon: zoomCenterLon, x: &zoomCurrXc, y: &zoomCurrYc)
		let a = scaleDescs[currScaleIdx].scale / scaleDescs[zoomStartScaleIndex].scale
		let am1 = 1.0 - a
#if false
		let XcDiff = zoomStartXc - zoomCurrXc
		let yRange1 = Double((tileContainerSubview.ymaxTileNum+1)*TILE_H)
		let YcDiff = (yRange0 - zoomStartYc) - (yRange1 - zoomCurrYc)
#else
		var XcDiff = 0.0, YcDiff = 0.0
		if (currScaleIdx != zoomStartScaleIndex) {
			XcDiff = zoomStartXc - zoomCurrXc
			let yRange1 = Double((tileContainerSubview.ymaxTileNum+1)*TILE_H)
			YcDiff = (yRange0 - zoomStartYc) - (yRange1 - zoomCurrYc)
		}
#endif
		let bounds = tileContainerSubview.bounds
		let xshift = (zoomCurrXc - Double(bounds.width)*0.5) * am1
		let yshift = (zoomCurrYc - Double(bounds.height)*0.5) * am1
		let ar = 1.0 / a
		let tx = (XcDiff + xshift) * ar
		let ty = (YcDiff - yshift) * ar
#if VERBOSE1
		print("tileContainerSubview.frame = \(tileContainerSubview.frame)")
		print("tileContainerSubview.center = \(tileContainerSubview.center)")
		print("tileContainerSubview.bounds = \(tileContainerSubview.bounds)")
		print("zoomCurrXc = \(zoomCurrXc)")
		print("zoomCurrYc = \(zoomCurrYc)")
		print("zoomStartXc = \(zoomStartXc)")
		print("zoomStartYc = \(zoomStartYc)")
		print("XcDiff = \(XcDiff) : YcDiff = \(YcDiff)")
		print("xshift = \(xshift) : yshift = \(yshift)")
		print("tx = \(tx)")
		print("ty = \(ty)")
#endif
		let cga = CGFloat(a)
		var affine = CGAffineTransformMakeScale(cga, cga)
		affine = CGAffineTransformTranslate(affine, CGFloat(tx), CGFloat(ty))
		tileContainerSubview.transform = affine
		let scaledMinZoomScale = minZoomScale * ar
		scrollView.minimumZoomScale = CGFloat(scaledMinZoomScale * 0.98)
		var tmpMaxZoomScale = maxZoomScale
		if (currScaleIdx != 0) {
			tmpMaxZoomScale = scaleDescs[currScaleIdx].scale / scaleDescs[currScaleIdx-1].scale
		}
		scrollView.maximumZoomScale = CGFloat(scaledMinZoomScale * tmpMaxZoomScale * 1.02)
		// prep new map tile data
		zoomInProcess = ZoomInProcess.MapChangeOngoing
		scrollViewDidScroll(scrollView)
		// swap map w/ animation
		if (mapChangeAnimation) {
			tileContainerSubview.alpha = 0.0
			tileContainerView.bringSubviewToFront(tileContainerSubview)
			//UIView.animateWithDuration(0.1,
			UIView.animateWithDuration(0.25,
				animations: {() -> Void in
					self.tileContainerSubview.alpha = 1.0
				},
				completion: {(Bool) -> Void in
					self.onTransitionAnimation = false
					// self.prevTileContainerSubview.alpha = 0.0  // don't do this, or it would cause prev view to get blank out w/ background color
				}
			)
		} else {
			tileContainerSubview.alpha = 1.0
			tileContainerView.bringSubviewToFront(tileContainerSubview)
			onTransitionAnimation = false
		}
#if VERBOSE1
		print("##### exit scrollViewDidZoom 5 #####")
#endif
	}

	// end zooming
	//
	func scrollViewDidEndZooming(scrollView: UIScrollView, withView view: UIView?, atScale scale: CGFloat) {
#if VERBOSE1
		print("*** end zoom: \(scale)")
		print("zoomInProcess = \(zoomInProcess)")
		print("tileContainerView.frame = \(tileContainerView.frame)")
		print("tileContainerView.bounds = \(tileContainerView.bounds) : center = \(tileContainerView.center)")
		print("tileContainerView: a = \(tileContainerView.transform.a) : b = \(tileContainerView.transform.b) : c = \(tileContainerView.transform.c) : d = \(tileContainerView.transform.d) : tx = \(tileContainerView.transform.tx) : ty = \(tileContainerView.transform.ty)")
		print("tileContainerSubview.frame = \(tileContainerSubview.frame)")
		print("tileContainerSubview.bounds = \(tileContainerSubview.bounds) : center = \(tileContainerSubview.center)")
		print("tileContainerSubview: a = \(tileContainerSubview.transform.a) : b = \(tileContainerSubview.transform.b) : c = \(tileContainerSubview.transform.c) : d = \(tileContainerSubview.transform.d) : tx = \(tileContainerSubview.transform.tx) : ty = \(tileContainerSubview.transform.ty)")
		print("centerXpos = \(tileContainerSubview.centerXpos) : centerYpos = \(tileContainerSubview.centerYpos)")
		print("zoomScale = \(scrollView.zoomScale)")
		print("contentOffset = \(scrollView.contentOffset)")
		print("contentSize = \(scrollView.contentSize)")
#endif
		zoomInProcess = ZoomInProcess.BusyNow
		scrollView.minimumZoomScale = CGFloat(minZoomScale*0.98)
		if (currScaleIdx == 0) {
			scrollView.maximumZoomScale = CGFloat(maxZoomScale*minZoomScale)
		} else {
			scrollView.maximumZoomScale = CGFloat(scaleDescs[currScaleIdx].scale/scaleDescs[currScaleIdx-1].scale*minZoomScale*1.02)
		}
		scrollView.zoomScale = scrollView.zoomScale * tileContainerSubview.transform.a
		tileContainerSubview.transform = CGAffineTransformIdentity
		let screenSiz = UIScreen.mainScreen().bounds.size
		let coffX = CGFloat(tileContainerSubview.centerXpos) * scrollView.zoomScale - screenSiz.width * 0.5
		let yrange = CGFloat(TILE_H * (tileContainerSubview.ymaxTileNum+1))
		let xrange = CGFloat(TILE_W * (tileContainerSubview.xmaxTileNum+1))
		let coffY = (yrange - CGFloat(tileContainerSubview.centerYpos)) * scrollView.zoomScale - screenSiz.height * 0.5
		scrollView.contentOffset = CGPointMake(coffX, coffY)
		tileContainerSubview.bounds = CGRectMake(0.0, 0.0, xrange, yrange)
		tileContainerSubview.center = CGPointMake(0.5*xrange, 0.5*yrange)
		let frame = CGRectMake(0.0, 0.0, tileContainerSubview.bounds.width*scrollView.zoomScale, tileContainerSubview.bounds.height*scrollView.zoomScale)
		tileContainerView.frame = frame
		scrollView.contentSize = CGSizeMake(xrange*scrollView.zoomScale, yrange*scrollView.zoomScale)
		zoomInProcess = ZoomInProcess.Ready
#if VERBOSE1
		print("*** after adjusted")
		print("tileContainerView.frame = \(tileContainerView.frame)")
		print("tileContainerView.bounds = \(tileContainerView.bounds) : center = \(tileContainerView.center)")
		print("tileContainerView: a = \(tileContainerView.transform.a) : b = \(tileContainerView.transform.b) : c = \(tileContainerView.transform.c) : d = \(tileContainerView.transform.d) : tx = \(tileContainerView.transform.tx) : ty = \(tileContainerView.transform.ty)")
		print("tileContainerSubview.frame = \(tileContainerSubview.frame)")
		print("tileContainerSubview.bounds = \(tileContainerSubview.bounds) : center = \(tileContainerSubview.center)")
		print("tileContainerSubview: a = \(tileContainerSubview.transform.a) : b = \(tileContainerSubview.transform.b) : c = \(tileContainerSubview.transform.c) : d = \(tileContainerSubview.transform.d) : tx = \(tileContainerSubview.transform.tx) : ty = \(tileContainerSubview.transform.ty)")
		print("zoomScale = \(scrollView.zoomScale)")
		print("contentOffset = \(scrollView.contentOffset)")
		print("contentSize = \(scrollView.contentSize)")
#endif
		for (var i = 0 ; i < tileContainerSubviews.count ; i++) {
			if (i != currScaleIdx) {
				tileContainerSubviews[i].alpha = 0.0
			}
		}
        if (mapAnnotation != nil) {
			mapAnnotation.scaleIdx = currScaleIdx
			mapAnnotation.centerXpos = tileContainerSubview.centerXpos
			mapAnnotation.centerYpos = tileContainerSubview.centerYpos
            mapAnnotation.endZooming()
			drawTrackLog()
        }
	}
	
	// layout subviews
	//
	override func viewDidLayoutSubviews() {
		super.viewDidLayoutSubviews()
		mapobj.xy2latlonWithScaleIndex(currScaleIdx, x: tileContainerSubview.centerXpos, y: tileContainerSubview.centerYpos, lat: &centerLat, lon: &centerLon)
		scrollView.frame = view.frame
		dispMapWithCenterLatLon()
		drawTrackLog()
		let collection = UITraitCollection(verticalSizeClass: .Regular)
		let currOrientation: UIInterfaceOrientation
		let sliderSize = min(view.frame.width, view.frame.height) * 0.8  // make size 80%
		let yoffset: CGFloat
		if (traitCollection.containsTraitsInCollection(collection)) {
			currOrientation = .Portrait
			let bottominset: CGFloat = 64.0
			yoffset = view.frame.height - sliderSize - bottominset
		} else {
			let bottominset: CGFloat = 20.0
			yoffset = view.frame.height - sliderSize - bottominset
			currOrientation = .LandscapeRight  // left/right doesn't matter
		}
		if (opsMode == MapMode.RouteEdit) {
			var ypos: CGFloat = 32.0+8.0
			if (currOrientation == .Portrait) {
				ypos = 64.0+8.0
			}
			guideMsgTop.constant = ypos
		}
		if (orientation != currOrientation) {
			// locate slider
			let zoomSideinset: CGFloat = 9.0
			let zoomTranslate = (-sliderSize+zoomImageSiz.height)*0.5
			var zoomAffinex = CGAffineTransformMakeTranslation(zoomTranslate+view.frame.width-zoomImageSiz.width-2*zoomSideinset, -zoomTranslate+yoffset)
			zoomAffinex = CGAffineTransformRotate(zoomAffinex, CGFloat(-M_PI_2))
			zoomSlider.transform = zoomAffinex
		}
	}
	
	var trackLogSiz: Int32 = 14*2400
	var singleTap: UITapGestureRecognizer!
	var mapAnnotation: MapAnnotationObj! = nil
	var longTap: UILongPressGestureRecognizer!
    
    var trackObj: TrackObj! = nil
    var routeObj: TrackObj! = nil
    var wayptObj: WaypointObj! = nil
    
	//let LOGFILE = "T131010061403.gol"
	let LOGFILE = "T150711070119.gol"
//	let ROUTEFILE = "要害山.rte"
	let ROUTEFILE = "塔ノ岳@160301233441.rte"
	var routeFile: String! = nil
//	let ROUTEFILE = "myarea.rte"
//	let WAYPTFILE = "要害山.wpt"
//	let WAYPTFILE = "ごんべさん.wpt"
	let WAYPTFILE = "塔ノ岳.wpt"
    var closeBtn: UIBarButtonItem! = nil
	var gpsRunning: Bool = false
	var gpsObj: GpsObject! = nil		// GPS logging object
	var gpsTrackObj: TrackObj! = nil	// track object for GPS log
//	var actCtrl: ActionController!

	// receive action bar result
	//
//	func actionControllerDone(tot: Bool) {
////		actCtrl.doneAction(actCtrl)
//		actCtrl = nil
//		print("actionControllerDone")
//		//print("exit with tot: \(tot)")
//	}
//
//	// call route list
//	//
//	func callRouteList(alert: UIAlertActionX) {
//		actCtrl.dismissViewControllerAnimated(true, completion: nil)
//		actCtrl = nil
//	}
	
	// receive route edit result
	//
	func receiveRouteEditResult(editedRtFile: String!) {
		if (routeObj != nil) {
			if (mapAnnotation != nil) {
				mapAnnotation.removeTrackObj(routeObj)
			}
			routeObj = nil
		}
		routeFile = editedRtFile
		if (editedRtFile != nil) {
			// recreate track object
			getRouteDataDir()
			let fileName = getRouteDataDir() + routeFile
			routeObj = TrackObj(fileName: fileName, numRec: 0, hasMarker: false)
			routeObj.trackPri = 0
			routeObj.setTrackColor([0.0, 0.0, 1.0, 1.0])
			if (mapAnnotation != nil) {
				mapAnnotation.addTrackObj(routeObj)
			}
		}
		mapAnnotation.purgeTrack()
		drawTrackLog()
	}
	
	// misc menu selected
	//
	func miscMenuSelected(action: PopMenuAction!) -> Bool {
		switch (action.tag) {
		case 4:  // waypoint
			let storyboard: UIStoryboard = UIStoryboard(name: "WaypointList", bundle: NSBundle.mainBundle())
			let wayptListViewController = storyboard.instantiateInitialViewController() as! WaypointListViewController
			let backButton = UIBarButtonItem(title: "地図", style: UIBarButtonItemStyle.Plain, target: nil, action: nil)
			let wptDat = WaypointEditData()
			wptDat.currentFile = wayptObj.fileName
			wptDat.editFile = wayptObj.fileName
			wptDat.mapVC = self
			wayptListViewController.wptEditDat = wptDat
			navigationItem.backBarButtonItem = backButton
			navigationController!.pushViewController(wayptListViewController, animated: true)
			break
		case 3: // route
			let storyboard: UIStoryboard = UIStoryboard(name: "RouteList", bundle: NSBundle.mainBundle())
			let routeListViewController = storyboard.instantiateInitialViewController() as! RouteListViewController
			routeListViewController.mapViewController = self
			routeListViewController.currentRoute = routeFile
			let backButton = UIBarButtonItem(title: "地図", style: UIBarButtonItemStyle.Plain, target: nil, action: nil)
			navigationItem.backBarButtonItem = backButton
			navigationController!.pushViewController(routeListViewController, animated: true)
			break
		default:
			break
		}
		return false
	}
	
	// tool bar button handler
	//
    func toolBarBtnClicked(button: UIButton) {
		switch (button.tag) {
		case 0:  // GPS button
			if (!gpsRunning) {
				if (gpsObj == nil) {
					gpsObj = GpsObject()
					gpsObj.trackObj = gpsTrackObj
					gpsObj.mapViewCtrl = self
				}
				gpsObj.startGps()
				gpsRunning = true
			} else {
				gpsObj.stopGps()
				gpsRunning = false
			}
			break
		case 4:  // misc
			let miscMenu = PopoverMenuController()
			miscMenu.sourceView = button
			miscMenu.sourceRect = button.bounds
			miscMenu.timeoutValue = 3.0
			miscMenu.arrowDirection = UIPopoverArrowDirection.Down
			miscMenu.addAction(PopMenuAction(textLabel: "設　定", accessoryType: .None, handler: miscMenuSelected))
			miscMenu.addAction(PopMenuAction(textLabel: "地図選択", accessoryType: .None, handler: miscMenuSelected))
			miscMenu.addAction(PopMenuAction(textLabel: "トラックログ", accessoryType: .None, handler: miscMenuSelected))
			miscMenu.addAction(PopMenuAction(textLabel: "ルート", accessoryType: .None, handler: miscMenuSelected))
			miscMenu.addAction(PopMenuAction(textLabel: "Waypoint", accessoryType: .None, handler: miscMenuSelected))
			presentViewController(miscMenu, animated: true, completion: nil)
			break
		case 1:
			tempFunc()
			break
		case 3:  // cutaway
			if (routeObj != nil) {
				let numRec = routeObj.getNumOfRecords()
				if (numRec < 2) {
					break
				}
				let logdata = routeObj.getLogData()
				let storyboard = UIStoryboard(name: "Cutaway", bundle: NSBundle.mainBundle())
				let cutawayvc = storyboard.instantiateInitialViewController() as! CutawayViewController
				cutawayvc.numRec = numRec
				cutawayvc.logdata = logdata
				cutawayvc.wo = wayptObj.wo
				var rtname = routeFile.substringWithRange(routeFile.startIndex..<routeFile.endIndex.advancedBy(-4))  // extract name part
				checkNameHasDate(&rtname)
				cutawayvc.routeName = rtname
///////////////////////////////////////////////////
				cutawayvc.currLat = 127609306	// 政次郎ノ頭
				cutawayvc.currLon = 501044737
///////////////////////////////////////////////////

				presentViewController(cutawayvc, animated: true, completion: nil)
			}
			break
		case 2: // 3D view
			let minviewController = MinViewController(checkStartable: true)
			if (minviewController != nil) {
				// we have all data files. go
#if false
				// 蛭ヶ岳(丹沢山)	27427.30249	27559.44414	1672.7
				minviewController!.lat = 127739166.0  // converted to mS, datum in Tokyo
				minviewController!.lon = 500911430.0
#else
				// set current map center location
				var tkylat = 0.0, tkylon = 0.0
				wgs2tokyo(centerLat, centerLon, &tkylat, &tkylon)
				minviewController!.lat = tkylat
				minviewController!.lon = tkylon
#endif
				presentViewController(minviewController!, animated: true, completion: nil)
			}
			break
		default:
			break
		}
    }

	// new GPS location data arrived
	//
	func newGpsLocation(numNewRec: Int, logdata: UnsafeMutablePointer<LOGDATA>) {
		let lat = Double(logdata[numNewRec-1].lat)
		let lon = Double(logdata[numNewRec-1].lon)
		if (centerLat == lat && centerLon == lon) {
			return
		}
#if false
		centerLat = lat
		centerLon = lon
		updateTrackLog()
		dispMapWithCenterLatLon()
#else
		updateTrackLog(numNewRec, logdata: logdata)
		drawTrackLog()
#endif
	}

	var panGesture: CoolPanGestureRecognizer! = nil
	var pinchGesture: UIPinchGestureRecognizer! = nil
	
	// reset TOT
	//
	func resetTOT(gesture: UIGestureRecognizer) {
		//print("***** reset TOT")
	}

	// create toolbar
	//
    func createToolBar() {
		// toolbar buttons
		let toolBtns: [[String]] = [["GPS", "GpsGray.png", "GpsHighlited.png"], ["表 示", "dispItem.png", "dispItemHighlited.png"], ["3  D", "MtFuji.png", "MtFujiHighlited.png"], ["行 程", "profile.png", "profileHighlited.png"], ["その他", "misc.png", "miscHighlited.png"]]
        // create toolbar. need to create UIButton for custome image
        // http://www.appgroup.co.uk/adding-a-uibarbuttonitem-with-a-custom-image/
		// http://stackoverflow.com/questions/18844681/how-to-make-custom-uibarbuttonitem-with-image-and-label
		toolBar = UIToolbar(frame: CGRectZero) // whatever since autolayout will set later
		//toolBar.autoresizingMask = UIViewAutoresizing.FlexibleWidth  // not necessary thanks to autolayout
		toolBar.backgroundColor = UIColor.whiteColor()
		let txtColor0 = UIColor(red: 0.55686274509804, green: 0.55686274509804, blue: 0.57647058823529, alpha:1.0)
		let txtColor = UIColor(red: 0.0, green: 0.5, blue: 1.0, alpha:1.0)
		let txtColor2 = UIColor(red: 0.8, green: 0.89411764705882, blue: 1.0, alpha:1.0)
		let rect = CGRectMake(0.0, 0.0, 44.0, 44.0)
		let imgInsets = UIEdgeInsetsMake(-12.0, 10.0, 0.0, 0.0)
		let txtInsets = UIEdgeInsetsMake(32.0, -23.0, 0.0, 0.0)
		var btnItm: [UIBarButtonItem] = []
		// distruibute buttons evenly
		// http://stackoverflow.com/questions/602717/aligning-uitoolbar-items
		// http://stackoverflow.com/questions/16022312/how-to-distribute-buttons-along-length-in-uitoolbar
		let flexSpace = UIBarButtonItem(barButtonSystemItem: .FlexibleSpace, target:nil, action: nil)
		for (var i = 0 ; i < toolBtns.count ; i++) {
			let btn = UIButton(frame: rect)
			btn.setTitle(toolBtns[i][0], forState: .Normal)
			btn.titleLabel!.font = UIFont.systemFontOfSize(12)
			if (i == 0) {
				btn.setTitleColor(txtColor0, forState: .Normal)
			} else {
				btn.setTitleColor(txtColor, forState: .Normal)
			}
			btn.setTitleColor(txtColor2, forState: .Highlighted)
			btn.titleEdgeInsets = txtInsets
			let normalImg = UIImage(named: toolBtns[i][1])
			btn.setImage(normalImg, forState: .Normal)
			let highlitedImg = UIImage(named: toolBtns[i][2])
			btn.setImage(highlitedImg, forState: .Highlighted)
			btn.imageEdgeInsets = imgInsets
			//btn.showsTouchWhenHighlighted = true
			btn.addTarget(self, action: "toolBarBtnClicked:", forControlEvents: .TouchUpInside)
			btnItm.append(UIBarButtonItem(customView: btn))
			if (i != toolBtns.count-1) {
				btnItm.append(flexSpace)
			}
			btn.tag = i
		}
		toolBar.items = btnItm
    }

    // single tap - display toolbar and search bar
	//
	func handleSingleTap(gesture: UITapGestureRecognizer) {
		resetTOT(gesture)
		// determine distance
		if (mapAnnotation == nil) {
            mapAnnotation = MapAnnotationObj(view: tileContainerView)
			mapAnnotation.mapViewController = self
			mapAnnotation.scrollView = scrollView
			mapAnnotation.scaleIdx = currScaleIdx
			mapAnnotation.centerXpos = tileContainerSubview.centerXpos
			mapAnnotation.centerYpos = tileContainerSubview.centerYpos
#if true
            if (trackObj == nil) {
                var fileName = NSSearchPathForDirectoriesInDomains(.DocumentDirectory, .UserDomainMask, true)[0] 
                fileName = fileName + "/logdata/" + LOGFILE
                trackObj = TrackObj(fileName: fileName, numRec: Int(trackLogSiz), hasMarker: false)
                trackObj.trackPri = 2
                trackObj.marker = true
				trackObj.startMarker = true
				trackObj.endMarker = true
                trackObj.setTrackColor([0.0, 1.0, 1.0, 1.0])
                trackObj.setTrakMarkerColor([0.0, 0.5, 1.0, 1.0])
            }
#endif
			if (gpsTrackObj == nil) {
				gpsTrackObj = TrackObj(numRec: 14*2400)
				gpsTrackObj.trackPri = 2
				gpsTrackObj.marker = true
				trackObj.startMarker = true
				trackObj.endMarker = true
				gpsTrackObj.setTrackColor([0.0, 1.0, 1.0, 1.0])
				gpsTrackObj.setTrakMarkerColor([0.0, 0.5, 1.0, 1.0])
			}
#if true
            if (routeObj == nil) {
				routeFile = ROUTEFILE
                var fileName = NSSearchPathForDirectoriesInDomains(.DocumentDirectory, .UserDomainMask, true)[0] 
                fileName = fileName + "/routedata/" + routeFile
                routeObj = TrackObj(fileName: fileName, numRec: 0, hasMarker: false)
                routeObj.trackPri = 0
                routeObj.setTrackColor([0.0, 0.0, 1.0, 1.0])
            }
#endif
            if (wayptObj == nil) {
                wayptObj = WaypointObj(fileName: WAYPTFILE)
				wayptObj.target = self
				wayptObj.action = "wayptTapped:"
            }
			mapAnnotation.mapObject = mapobj
#if false
            mapAnnotation.addTrackObj(trackObj)
#endif
//			mapAnnotation.addTrackObj(gpsTrackObj)
			mapAnnotation.addTrackObj(routeObj)
            mapAnnotation.addWayptObj(wayptObj)
			drawTrackLog()
		} else {
			if (opsMode == MapMode.MapDisplay) {
				// regular map display
				let screenSiz = UIScreen.mainScreen().bounds.size
				if (toolBar == nil) {
					createToolBar()
				}
				if (locSrchViewController == nil) {
					let storyboard = UIStoryboard(name: "LocationSrch", bundle: NSBundle.mainBundle())
					locSrchViewController = storyboard.instantiateInitialViewController() as! LocationSearchViewController
					addChildViewController(locSrchViewController)
					view.addSubview(locSrchViewController.view)
					locSrchViewController.delegate = self
					locSrchViewController.view.layer.zPosition = 1000.0
				}
				let srchView = locSrchViewController.view
				var navHeight: CGFloat = 32.0
				let orientation = UIApplication.sharedApplication().statusBarOrientation
				if (orientation == UIInterfaceOrientation.Portrait || orientation == UIInterfaceOrientation.PortraitUpsideDown) {
					navHeight = 64.0
				}
				if (!toolBarVisible) {
					view.addSubview(toolBar)
					setToolbarConstraints(toolBar)
					toolBar.frame = CGRectMake(0.0, screenSiz.height, screenSiz.width, 44.0)
					toolBarVisible = true
					srchView.hidden = false
					srchView.frame.origin.y -= navHeight
					UIView.animateWithDuration(0.25, animations: {() -> Void in
						self.toolBar.frame = CGRectMake(0.0, screenSiz.height-44.0, screenSiz.width, 44.0)
						srchView.layer.frame.origin.y = 0.0
					})
				} else {
					UIView.animateWithDuration(0.25, animations: {() -> Void in
						self.toolBar.frame = CGRectMake(0.0, screenSiz.height, screenSiz.width, 44.0)
						srchView.layer.frame.origin.y = -navHeight
						}, completion: {(Bool) -> Void in
							self.toolBar.removeFromSuperview()
							srchView.hidden = true
							srchView.layer.frame.origin.y = 0.0
					})
					toolBarVisible = false
				}
				//setNeedsStatusBarAppearanceUpdate()
				return
			} else if (opsMode == MapMode.RouteEdit) {
				// route editing
				routeEditSingleTap(gesture)
			}
		}
	}

	// waypoint button handler
	//
	func wayptTapped(btn: LabelButton) {
		let wptDat = WaypointEditData()
		wptDat.currentFile = wayptObj.fileName
		wptDat.editFile = wayptObj.fileName
		wptDat.mapVC = self
		wptDat.widx = btn.tag
		let storyboard: UIStoryboard = UIStoryboard(name: "WaypointNameEdit", bundle: NSBundle.mainBundle())
		let wayptEditViewController = storyboard.instantiateInitialViewController() as! WaypointEditViewController
		wayptEditViewController.wptEditDat = wptDat
		let backButton = UIBarButtonItem(title: "地図", style: UIBarButtonItemStyle.Plain, target: nil, action: nil)
		navigationItem.backBarButtonItem = backButton
		navigationController!.pushViewController(wayptEditViewController, animated: true)
	}

	// waypoint edit result
	//
	func waypointEditResult(cmd: WptCmd, wptDat: WaypointEditData) {
		if (cmd == .updateStr) {
			if (wayptObj != nil) {
				if (wptDat.wayptStr != nil) {
					wayptObj.setLabelText(wptDat.widx, title: wptDat.wayptStr)
					wayptObj.updateNameOfWayptrec(wptDat.widx, title: wptDat.wayptStr)
				} else {
					wayptObj.removeWaypointAt(wptDat.widx)
				}
			}
		} else if (cmd == .jump) {
			centerLat = Double(wptDat.lat)
			centerLon = Double(wptDat.lon)
			dispMapWithCenterLatLon()
		} else if (cmd == .removeWptObj) {
			if (wayptObj != nil) {
				let nwp = wayptObj.nrec
				for (var i = 0 ; i < nwp ; i++) {
					wayptObj.removeWaypointAt(0)
				}
				mapAnnotation.removeWayptObj(wayptObj)
				wayptObj = nil
			}
		} else if (cmd == .setWptObj) {
			wayptObj = WaypointObj(fileName: wptDat.currentFile)
			wayptObj.target = self
			wayptObj.action = "wayptTapped:"
			mapAnnotation.addWayptObj(wayptObj)
			mapAnnotation.annotateMap()
		}
	}
	
	
	func gpsBtn(sender: AnyObject) {
    }
	
    func tempFunc() {
		print("centerX = \(tileContainerSubview.centerXpos)")
		var ad = 2.0
//		ad = 0.5
		let W = Double((tileContainerSubview.xmaxTileNum+1) * TILE_W)
		let H = Double((tileContainerSubview.ymaxTileNum+1) * TILE_H)
		let w = W * ad
		let h = H * ad
		let tx = (1.0-ad)*(tileContainerSubview.centerXpos-W*0.5)/ad
		let ty = (1.0-ad)*(H-tileContainerSubview.centerYpos-H*0.5)/ad
		let affine = CGAffineTransformMakeScale(CGFloat(ad), CGFloat(ad))
		let prevAffine = CGAffineTransformTranslate(affine, CGFloat(tx), CGFloat(ty))
		tileContainerSubview.transform = prevAffine
	}
    
    func viewin3d(sender: AnyObject) {
        
    }

	// waypoint index for long press. -1 for new waypoint, else waypoint index. valid while long press
	var wayptIdx = 0

	// long press
	//
	func handleLongPress(gesture: UILongPressGestureRecognizer) {
		resetTOT(gesture)
		if (mapAnnotation == nil || wayptObj == nil) {
			return
		}
		let tpoint = gesture.locationInView(view)
		switch (gesture.state) {
		case UIGestureRecognizerState.Began:
			let within = mapAnnotation.checkPointInPins(wayptObj, poi: tpoint)
			if (within.widx == -1) {
				// new waypoint
				wayptObj.addWaypointWithScreenPoint(tpoint, iconid: 0, title: "ごんべ山", btnHidden: false)
				wayptIdx = -1
			} else {
				// long press w/in existing waypoint. edit location. stop scroll
				wayptIdx = within.widx
				mapAnnotation.setInitialWaypoint(wayptObj, widx: within.widx, poi: tpoint, upword: true, onTrack: false)
			}
			break
		case UIGestureRecognizerState.Changed:
			if (wayptIdx != -1) {
				mapAnnotation.movingWaypoint(wayptObj, widx: wayptIdx, poi: tpoint)
			}
			break
		case UIGestureRecognizerState.Ended:
			if (wayptIdx != -1) {
				mapAnnotation.moveEndWaypoint(wayptObj, widx: wayptIdx, poi: tpoint, upword: true)
			}
			break
		default:
			break
		}
	}

	// draw track log
	//
	func drawTrackLog() {
		if (mapAnnotation != nil) {
			mapAnnotation.annotateMap()
		}
	}

	// update track log
	//
	func updateTrackLog(var numNewRec: Int, logdata: UnsafeMutablePointer<LOGDATA>) {
		if (mapAnnotation != nil) {
			let distIdx = mapAnnotation.getTrackDistanceIdx()
			let lastlog = gpsTrackObj.getLastTrackPoints()
			mapAnnotation.updateTrackLogs(numNewRec, logdata: logdata)
			if (lastlog.count != 0) {
				logdata[numNewRec++] = lastlog[0]
				logdata[numNewRec++] = lastlog[1]
			}
			gpsTrackObj.setLastTrackPoints(distIdx)
		}
	}

	// view will appear
	//
	override func viewWillAppear(animated: Bool) {
		// this is crucial! or very weird behavior would result
		// http://stackoverflow.com/questions/26369046/push-pop-view-controller-with-navigation-bar-from-view-controller-without-navi
		navigationController?.setNavigationBarHidden(true, animated: animated)
		self.navigationItem.hidesBackButton = true
		super.viewWillAppear(animated)
	}

	override func viewDidAppear(animated: Bool) {
		print("MapViewController:viewDidAppear")
#if false //true
		navigationController!.navigationBarHidden = true
#endif
		super.viewDidAppear(animated)
	}
#if DEBUG && true
	override func viewWillDisappear(animated: Bool) {
//		if (navigationController != nil) {
//			navigationController!.navigationBarHidden = false
//		}
		print("MapViewController:viewWillDisappear")
		super.viewWillDisappear(animated)
	}
	override func viewDidDisappear(animated: Bool) {
		print("MapViewController:viewDidDisappear")
		super.viewDidDisappear(animated)
	}
#endif
	var tileContainerSubviews: [TileContainerSubview] = []	// tile container subviews, subview of tileContainerView
	
	// create views for map
	//
	func createViewsForMap(scaleDescs: [ScaleDesc]) -> [TileContainerSubview] {
		let numViews = scaleDescs.count
		var tmpTileContainerSubviews: [TileContainerSubview] = []
		for (var i = 0 ; i < numViews ; i++) {
			let newTileContainerSubview = TileContainerSubview()
			newTileContainerSubview.xmaxTileNum = scaleDescs[i].xmaxTileNum
			newTileContainerSubview.ymaxTileNum = scaleDescs[i].ymaxTileNum
			newTileContainerSubview.scaleIdx = i
			newTileContainerSubview.layer.drawsAsynchronously = drawAsync
			newTileContainerSubview.contentMode = UIViewContentMode.TopLeft
			newTileContainerSubview.clearsContextBeforeDrawing = false
			newTileContainerSubview.frame = CGRectMake(0, 0, CGFloat(TILE_W*(newTileContainerSubview.xmaxTileNum+1)), CGFloat(TILE_H*(newTileContainerSubview.ymaxTileNum+1)))
#if DEBUG
			if (i & 1 != 0) {
				newTileContainerSubview.backgroundColor = UIColor.redColor() //UIColor(white: 1.0, alpha:0.0)
			} else {
				newTileContainerSubview.backgroundColor = UIColor.blueColor()
			}
#else
			newTileContainerSubview.backgroundColor = UIColor.whiteColor()
#endif
			newTileContainerSubview.alpha = 0.0
			tmpTileContainerSubviews.append(newTileContainerSubview)
		}
		return tmpTileContainerSubviews
	}
	
#if false
	override func prefersStatusBarHidden() -> Bool {
		let orientation = UIApplication.sharedApplication().statusBarOrientation
		if (orientation == UIInterfaceOrientation.Portrait || orientation == UIInterfaceOrientation.PortraitUpsideDown) {
			return false
		}
		return true
	}
#endif
	
	// zoom slider
	var zoomSlider: ExtUISlider!	// zoom slider
	var zoomImageSiz = CGSize(width: 0, height: 0)

	// setup zoom slider
	//
	func setupZoomSlider() {
		let zoomImage = UIImage(named: "mapzoom.png")!
		let sliderSize = min(view.frame.width, view.frame.height) * 0.8  // make size 80%
		zoomImageSiz = zoomImage.size
		let zoomypos = zoomImageSiz.height*0.5 - 3.0  // -3 for sliderHeight/2
		// since this slider is vertical, we put at (0,0) and move w/ affine transfrom
		let zoomframe = CGRectMake(0.0, zoomypos, sliderSize, 6.0)
		zoomSlider = ExtUISlider(frame: zoomframe)
		zoomSlider.setThumbImage(zoomImage, forState: .Normal)
		zoomSlider.layer.zPosition = 10.0
		zoomSlider.addTarget(self, action: "handleZoomSliderBegin:", forControlEvents: .TouchDown)
		zoomSlider.addTarget(self, action: "handleZoomSliderChanged:", forControlEvents: .ValueChanged)
		zoomSlider.addTarget(self, action: "handleZoomSliderEnded:", forControlEvents: .TouchUpInside)
		zoomSlider.addTarget(self, action: "handleZoomSliderEnded:", forControlEvents: .TouchUpOutside)
		zoomSlider.backgroundColor = UIColor.whiteColor()
		zoomSlider.layer.cornerRadius = 3.0
		view.addSubview(zoomSlider)
	}
	
	// initial slider value of binocular
	var initialBino: Float = 0.0
	var updatingBinoSlide = false
	
	// handle bino slider begin
	//
	func handleZoomSliderBegin(slider: UISlider) {
	}
	
	// handle bino slider ended
	//
	func handleZoomSliderEnded(slider: UISlider) {
	}
	
	// handle bino slider change
	//
	func handleZoomSliderChanged(slider: UISlider) {
	}
	
	// view loaded
	//
	override func viewDidLoad() {
		super.viewDidLoad()
		// setup dispatch ques for background tile set
		srque = dispatch_queue_create(nil, DISPATCH_QUEUE_SERIAL)
		dspgrp = dispatch_group_create()
		dsem = dispatch_semaphore_create(1)
		wsem = dispatch_semaphore_create(1)
		msem = dispatch_semaphore_create(1)
		bsem = dispatch_semaphore_create(1)
		mapobj = MapObject()
		mapobj.currMapGroup = "PASV"
		scaleDescs = mapobj.scaleDesc
		minZoomScale = 0.35  // I think this should come from parm file...
#if true
		scrollView = MapScrollview()
        scrollView.delaysContentTouches = false
		//scrollView = TileScrollView()
		scrollView.frame = view.bounds
#else
		scrollView.frame = UIScreen.mainScreen().bounds
#endif
		scrollView.scrollsToTop = false
		scrollView.layer.drawsAsynchronously = drawAsync
		scrollView.bouncesZoom = false
		scrollView.delegate = self
#if DEBUG
		scrollView.backgroundColor = UIColor.yellowColor() // UIColor.blackColor() //UIColor.whiteColor() // UIColor.clearColor() // UIColor.redColor()
#else
		scrollView.backgroundColor = UIColor.whiteColor()
#endif
#if true //false
		view.addSubview(scrollView)
		view.layer.drawsAsynchronously = drawAsync
#endif
		tileContainerView = TileContainerView()
		scrollView.addSubview(tileContainerView)
		tileContainerView.scrollView = scrollView  // set parent scroll view for track display
		scrollView.contentMode = UIViewContentMode.TopLeft
		tileContainerView.layer.drawsAsynchronously = drawAsync
		tileContainerView.contentMode = UIViewContentMode.TopLeft
		tileContainerSubviews = createViewsForMap(scaleDescs)
		tileContainerView.tileContainerSubviews = tileContainerSubviews
		for (var i = 0 ; i < scaleDescs.count ; i++) {
			tileContainerView.addSubview(tileContainerSubviews[i])
		}

		// tap gesture recognizer
		singleTap = UITapGestureRecognizer(target: self, action: "handleSingleTap:")
		singleTap.numberOfTapsRequired = 1
		scrollView.addGestureRecognizer(singleTap)
		longTap = UILongPressGestureRecognizer(target: self, action: "handleLongPress:")
		longTap.minimumPressDuration = 0.8
		scrollView.addGestureRecognizer(longTap)
#if false
		// add some others for timeout reset
		panGesture = UIPanGestureRecognizer(target: self, action: "resetTOT:")
		scrollView.addGestureRecognizer(panGesture)
		pinchGesture = UIPinchGestureRecognizer(target: self, action: "resetTOT:")
		scrollView.addGestureRecognizer(pinchGesture)
#endif

		// get current screen size in point
		let minDispTileSiz = DTILE_W * minZoomScale
		let screenSiz = UIScreen.mainScreen().bounds.size
		print("screenSiz = \(screenSiz)")
		let sww = Double(screenSiz.width) * 1.01  // make it slightly larger to avoid possible rounding effect of floating point arithmatic
		let shh = Double(screenSiz.height) * 1.01
		var nx = Int32(sww / minDispTileSiz) + 1
		if (sww % minDispTileSiz != 0.0) {
			nx++
		}
		var ny = Int32(shh / minDispTileSiz) + 1
		if (shh % minDispTileSiz != 0.0) {
			ny++
		}
		nmaxTiles = 2 * nx * ny + (nx * ny / 2) // we create up to this number of sub layers for tiles
		print("nmaxTiles-1 = \(nmaxTiles)")
		// set center to Tokyo station
		setCurrentScale(1)
		tileContainerSubviews[tileContainerView.currScaleIdx].alpha = 1.0
		tileContainerView.bringSubviewToFront(tileContainerSubviews[tileContainerView.currScaleIdx])

#if false
		centerLat = Deg2Int(35, 40, 40, 0)
		centerLon = Deg2Int(139, 46, 13, 67)
#elseif false
		centerLat = 130794933   // yarigatake
		centerLon = 495562480
#elseif true
		centerLat = 128428876   // daizokyoji yama
		centerLon = 499048986
#elseif true
		centerLat = 127987770	// my area
		centerLon = 502812564
#elseif true
		tileContainerSubview.centerXpos = Double((tileContainerSubview.xmaxTileNum+1)*TILE_W/2)
		tileContainerSubview.centerYpos = Double((tileContainerSubview.ymaxTileNum+1)*TILE_H/2)
		mapobj.xy2latlon(tileContainerSubview.centerXpos, y: tileContainerSubview.centerYpos, lat: &centerLat, lon: &centerLon)
#endif
#if false
		tokyo2wgs(centerLat, centerLon, &centerLat, &centerLon)
#endif
		print("x = \(tileContainerSubview.centerXpos) : y = \(tileContainerSubview.centerYpos)")

		refZoomScale = 1.0
		scrollView.zoomScale = 1.0
		tileContainerView.frame = tileContainerSubview.frame
		scrollView.contentSize = tileContainerSubview.bounds.size

		print("bounds = \(tileContainerView.bounds)")
		print("frame = \(tileContainerView.frame)")
		print("sub-frame0 = \(tileContainerSubviews[0].frame)")
		print("sub-frame1 = \(tileContainerSubviews[1].frame)")

		print("actions = \(tileContainerSubviews[0].layer.actions)")
#if false
		print("actions = \(tileContainerSubviews[1].layer.actions)")
#endif
		maxZoomScale = 3.0
		var currMaxZoomScale = maxZoomScale
		if (currScaleIdx != 0) {
			currMaxZoomScale = scaleDescs[currScaleIdx].scale / scaleDescs[currScaleIdx-1].scale
		}
		scrollView.minimumZoomScale = CGFloat(minZoomScale * 0.98)
		scrollView.maximumZoomScale = CGFloat(minZoomScale * currMaxZoomScale * 1.02)

#if DEBUG
		// grid lines layer for tests
		let scale = UIScreen.mainScreen().scale
		let iscale = Int(scale)
		let ixwidth = Int(screenSiz.width)
		let iyheight = Int(screenSiz.height)
		let colorSpace = CGColorSpaceCreateDeviceRGB()
		let ctx = CGBitmapContextCreate(nil, iscale*ixwidth, iscale*iyheight, 8, iscale*ixwidth*4, colorSpace, CGImageAlphaInfo.PremultipliedLast.rawValue)
		CGContextScaleCTM(ctx, scale, scale)
		CGContextSetLineWidth(ctx, 2)
		let lineColor = CGColorCreate(colorSpace, [0.0, 1.0, 0.0, 1.0])
		CGContextSetStrokeColorWithColor(ctx, lineColor)
		CGContextMoveToPoint(ctx, 0.0, screenSiz.height*0.5)
		CGContextAddLineToPoint(ctx, screenSiz.width, screenSiz.height*0.5)
		CGContextDrawPath(ctx, CGPathDrawingMode.Stroke)
		CGContextMoveToPoint(ctx, 0.0, screenSiz.height*0.25)
		CGContextAddLineToPoint(ctx, screenSiz.width, screenSiz.height*0.25)
		CGContextDrawPath(ctx, CGPathDrawingMode.Stroke)
		CGContextMoveToPoint(ctx, 0.0, screenSiz.height*0.75)
		CGContextAddLineToPoint(ctx, screenSiz.width, screenSiz.height*0.75)
		CGContextDrawPath(ctx, CGPathDrawingMode.Stroke)
		CGContextMoveToPoint(ctx, screenSiz.width*0.5, 0.0)
		CGContextAddLineToPoint(ctx, screenSiz.width*0.5, screenSiz.height)
		CGContextDrawPath(ctx, CGPathDrawingMode.Stroke)
		CGContextMoveToPoint(ctx, screenSiz.width*0.25, 0.0)
		CGContextAddLineToPoint(ctx, screenSiz.width*0.25, screenSiz.height)
		CGContextDrawPath(ctx, CGPathDrawingMode.Stroke)
		CGContextMoveToPoint(ctx, screenSiz.width*0.75, 0.0)
		CGContextAddLineToPoint(ctx, screenSiz.width*0.75, screenSiz.height)
		CGContextDrawPath(ctx, CGPathDrawingMode.Stroke)
		let clayer = CALayer()
		clayer.frame = UIScreen.mainScreen().bounds
		clayer.contents = CGBitmapContextCreateImage(ctx)
		view.layer.addSublayer(clayer)
#endif
//		opsMode = MapMode.RouteEdit
//		opsMode = MapMode.MapDisplay
		setMapMode(MapMode.MapDisplay, any: nil)
		setupZoomSlider()
		automaticallyAdjustsScrollViewInsets = false  // this to avoid view contents to push down by 20
		zoomInProcess = ZoomInProcess.Ready
		dispMapWithCenterLatLon()
	}

	override func didReceiveMemoryWarning() {
		super.didReceiveMemoryWarning()
		// Dispose of any resources that can be recreated.
	}
}

//
// create CG image ref from memory data array
//
#if DEBUG
// debug version shows two text strings. (tile number and tile sequence number)
func createCGImageFromBitmap(text: String, text2: String, bitmap: UnsafeMutablePointer<UInt8>, width: Int, height: Int) -> CGImageRef {
	let colorSpace = CGColorSpaceCreateDeviceRGB()
	let context = CGBitmapContextCreate(bitmap, width, height, 8, width * 4, colorSpace, CGImageAlphaInfo.NoneSkipLast.rawValue)
	// gen string
	let range = CFRangeMake(0, CFStringGetLength(text))
	let range2 = CFRangeMake(0, CFStringGetLength(text2))
	let attrString = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0)
	let attrString2 = CFAttributedStringCreateMutable(kCFAllocatorDefault, 0)
	CFAttributedStringReplaceString(attrString, CFRangeMake(0, 0), text)
	CFAttributedStringReplaceString(attrString2, CFRangeMake(0, 0), text2)
	// set font
	let font = CTFontCreateWithName("Helvetica", 40, nil)
	CFAttributedStringSetAttribute(attrString, range, kCTFontAttributeName, font)
	CFAttributedStringSetAttribute(attrString2, range2, kCTFontAttributeName, font)
	// set color
	let components: [CGFloat] = [1.0, 0.0, 1.0, 1.0]
	let components2: [CGFloat] = [0.0, 0.0, 1.0, 1.0]
	let txtcolor = CGColorCreate(colorSpace, components)
	let txtcolor2 = CGColorCreate(colorSpace, components2)
	CFAttributedStringSetAttribute(attrString, range, kCTForegroundColorAttributeName, txtcolor)
	CFAttributedStringSetAttribute(attrString2, range2, kCTForegroundColorAttributeName, txtcolor2)
	// gen path to draw in rect
	let path = CGPathCreateMutable()
	let path2 = CGPathCreateMutable()
	let bounds = CGRectMake(4, 4, 250, 100)
	let bounds2 = CGRectMake(4, 44, 250, 100)
	CGPathAddRect(path, nil, bounds)
	CGPathAddRect(path2, nil, bounds2)
	// gen CTFrame using CTFramesetter
	let framesetter = CTFramesetterCreateWithAttributedString(attrString)
	let framesetter2 = CTFramesetterCreateWithAttributedString(attrString2)
	let frame = CTFramesetterCreateFrame(framesetter, CFRangeMake(0, 0), path, nil)
	let frame2 = CTFramesetterCreateFrame(framesetter2, CFRangeMake(0, 0), path2, nil)
	// drame text in bitmap context
	CTFrameDraw(frame, context!)
	CTFrameDraw(frame2, context!)
	let result = CGBitmapContextCreateImage(context)
	return result!
}
#else
func createCGImageFromBitmap(bitmap: UnsafeMutablePointer<UInt8>, width: Int, height: Int) -> CGImageRef {
	let colorSpace = CGColorSpaceCreateDeviceRGB()
	let context = CGBitmapContextCreate(bitmap, width, height, 8, width * 4, colorSpace, CGImageAlphaInfo.NoneSkipLast.rawValue)
	let result = CGBitmapContextCreateImage(context)
	return result!
}
#endif
