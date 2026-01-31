/*
    Copyright © 2020, Inochi2D Project
    Copyright © 2024, nijigenerate Project
    Distributed under the 2-Clause BSD License, see LICENSE file.
    
    Authors: Luna Nielsen
*/
module nlshim;
//public import nlshim.nijilive;
public import nlshim.math;
public import nlshim.phys;
public import nlshim.fmt;
public import nlshim.core;
public import nlshim.ver;
public import nlshim.utils.snapshot;

private double currentTime_ = 0;
private double lastTime_ = 0;
private double deltaTime_ = 0;
private double function() tfunc_;

/**
    Initializes nijilive
    Run this after OpenGL context has been set current
*/
void inInit(double function() timeFunc) {
    initRenderer();
    tfunc_ = timeFunc;
}

void inSetTimingFunc(double function() timeFunc) {
    tfunc_ = timeFunc;
}

/**
    Run this at the start of your render/game loop
*/
void inUpdate() {
    currentTime_ = tfunc_();
    deltaTime_ = currentTime_-lastTime_;
    lastTime_ = currentTime_;
}

/**
    Gets the time difference between the last frame and the current frame
*/
public double deltaTime() {
    return deltaTime_;
}

/**
    Gets the last frame's time step
*/
double lastTime() {
    return lastTime_;
}

/**
    Gets the current time step
*/
double currentTime() {
    return currentTime_;
}
